package ai.flutterclaw.flutterclaw

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream

/**
 * Handles the "ai.flutterclaw/sandbox" MethodChannel on Android.
 *
 * Provides a sandboxed Linux (Alpine) shell environment using PRoot.
 * PRoot is packaged as libproot.so in jniLibs and extracted by Android
 * to nativeLibraryDir at install time.
 *
 * The Alpine rootfs is downloaded on first use and extracted to the app's
 * internal storage using a pure-Kotlin tar.gz extractor (Android does not
 * ship a `tar` binary).
 */
class SandboxHandler(private val context: Context) : EventChannel.StreamHandler {

    companion object {
        private const val TAG = "SandboxHandler"
        private const val ALPINE_VERSION = "3.21"
        private const val ALPINE_RELEASE = "3.21.3"

        private val ALPINE_URLS = mapOf(
            "arm64-v8a" to "https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/releases/aarch64/alpine-minirootfs-$ALPINE_RELEASE-aarch64.tar.gz",
            "armeabi-v7a" to "https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/releases/armv7/alpine-minirootfs-$ALPINE_RELEASE-armv7.tar.gz",
            "x86_64" to "https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/releases/x86_64/alpine-minirootfs-$ALPINE_RELEASE-x86_64.tar.gz",
        )

        private val ALPINE_SHA256 = mapOf(
            "arm64-v8a" to "",
            "armeabi-v7a" to "",
            "x86_64" to "",
        )

        private const val MAX_OUTPUT_BYTES = 65_536
        private const val TAR_BLOCK_SIZE = 512
    }

    private val sandboxDir get() = File(context.filesDir, "sandbox")
    private val rootfsDir get() = File(sandboxDir, "rootfs")
    private val prootBin get() = File(context.applicationInfo.nativeLibraryDir, "libproot.so")
    private val loaderBin get() = File(context.applicationInfo.nativeLibraryDir, "libproot-loader.so")
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()
    private val activeProcesses = CopyOnWriteArrayList<Process>()

    // Active PTY master fd for stdin writes (set during PTY-based streaming, -1 otherwise).
    @Volatile
    private var activePtyMasterFd: Int = -1

    // ─── EventChannel StreamHandler ──────────────────────────────────────────────

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        // Command args are passed via receiveBroadcastStream(args) from Dart.
        // Start streaming execution now that the sink is guaranteed to be set.
        if (arguments is Map<*, *>) {
            val command = arguments["command"] as? String ?: return
            val timeoutMs = (arguments["timeout_ms"] as? Number)?.toLong() ?: 30000
            val workingDir = arguments["working_dir"] as? String ?: "/root"
            startStreamingExec(command, timeoutMs, workingDir)
        }
    }

    override fun onCancel(arguments: Any?) {
        // Kill active processes when the Dart side cancels the stream
        for (p in activeProcesses) {
            p.destroyForcibly()
        }
        eventSink = null
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "sandbox_status" -> handleStatus(result)
            "sandbox_setup" -> handleSetup(result)
            "sandbox_exec" -> handleExec(call, result)
            "sandbox_kill" -> handleKill(result)
            "sandbox_write_stdin" -> handleWriteStdin(call, result)
            else -> result.notImplemented()
        }
    }

    fun cleanup() {
        for (p in activeProcesses) {
            p.destroyForcibly()
        }
        activeProcesses.clear()
    }

    // ─── Status ──────────────────────────────────────────────────────────────────

    private fun isRootfsValid(): Boolean {
        // busybox is the real binary; /bin/sh is a symlink that may not survive
        // extraction on some Android filesystems. Check both.
        return File(rootfsDir, "bin/busybox").exists() || File(rootfsDir, "bin/sh").exists()
    }

    private fun handleStatus(result: MethodChannel.Result) {
        val ready = prootBin.exists() && loaderBin.exists() && isRootfsValid()
        Log.d(TAG, "status: proot=${prootBin.exists()}, loader=${loaderBin.exists()} (${loaderBin.absolutePath}), rootfs=${isRootfsValid()}, ready=$ready")

        result.success(mapOf(
            "ready" to ready,
            "platform" to "android",
            "proot_available" to prootBin.exists(),
            "loader_available" to loaderBin.exists(),
            "rootfs_available" to isRootfsValid(),
        ))
    }

    // ─── Setup ───────────────────────────────────────────────────────────────────

    private fun handleSetup(result: MethodChannel.Result) {
        executor.execute {
            try {
                if (prootBin.exists() && loaderBin.exists() && isRootfsValid()) {
                    postSuccess(result, mapOf("ready" to true))
                    return@execute
                }

                if (!prootBin.exists()) {
                    postSuccess(result, mapOf(
                        "error" to true,
                        "message" to "PRoot binary not found at ${prootBin.absolutePath}. " +
                                "Ensure libproot.so is packaged in jniLibs.",
                    ))
                    return@execute
                }

                if (!loaderBin.exists()) {
                    postSuccess(result, mapOf(
                        "error" to true,
                        "message" to "PRoot loader not found at ${loaderBin.absolutePath}. " +
                                "Ensure libproot-loader.so is packaged in jniLibs.",
                    ))
                    return@execute
                }

                sandboxDir.mkdirs()
                val tarball = File(sandboxDir, "alpine-minirootfs.tar.gz")

                // Clean up stale rootfs from previous failed extraction attempts.
                if (rootfsDir.exists() && !isRootfsValid()) {
                    Log.w(TAG, "Removing invalid rootfs from previous attempt")
                    rootfsDir.deleteRecursively()
                }

                // Download rootfs if not cached or if previous download is too small.
                val minTarballSize = 500_000L // Alpine minirootfs is ~3MB
                if (!tarball.exists() || tarball.length() < minTarballSize) {
                    if (tarball.exists()) {
                        Log.w(TAG, "Tarball too small (${tarball.length()} bytes), re-downloading")
                        tarball.delete()
                    }
                    val abi = detectAbi()
                    val url = ALPINE_URLS[abi]
                        ?: throw IllegalStateException("No Alpine rootfs URL for ABI: $abi")

                    Log.d(TAG, "Downloading Alpine rootfs for $abi from $url")
                    downloadFile(url, tarball)
                    Log.d(TAG, "Download complete: ${tarball.length()} bytes")

                    val expectedSha = ALPINE_SHA256[abi]
                    if (!expectedSha.isNullOrEmpty()) {
                        val actualSha = sha256(tarball)
                        if (actualSha != expectedSha) {
                            tarball.delete()
                            throw SecurityException(
                                "SHA-256 mismatch. Expected: $expectedSha, got: $actualSha"
                            )
                        }
                    }
                }

                // Extract rootfs using pure-Kotlin tar.gz extractor.
                if (!isRootfsValid()) {
                    // Clean up any partial extraction
                    if (rootfsDir.exists()) rootfsDir.deleteRecursively()
                    rootfsDir.mkdirs()

                    Log.d(TAG, "Extracting rootfs (tarball=${tarball.length()} bytes) to ${rootfsDir.absolutePath}")
                    val filesExtracted = extractTarGz(tarball, rootfsDir)
                    Log.d(TAG, "Extracted $filesExtracted entries")

                    // Ensure /bin/sh exists. In Alpine, it's a symlink to busybox,
                    // but symlink creation can fail on some Android filesystems.
                    ensureBinSh()

                    // Set up DNS resolution.
                    val resolv = File(rootfsDir, "etc/resolv.conf")
                    resolv.parentFile?.mkdirs()
                    resolv.writeText("nameserver 8.8.8.8\nnameserver 8.8.4.4\n")

                    // Log what we got for debugging
                    val rootContents = rootfsDir.list()?.toList() ?: emptyList()
                    val binContents = File(rootfsDir, "bin").list()?.toList() ?: emptyList()
                    val binShExists = File(rootfsDir, "bin/sh").exists()
                    val binShIsLink = try { java.nio.file.Files.isSymbolicLink(File(rootfsDir, "bin/sh").toPath()) } catch (_: Exception) { false }
                    Log.d(TAG, "rootfs/ contents: $rootContents")
                    Log.d(TAG, "rootfs/bin/ contents: ${binContents.take(20)}")
                    Log.d(TAG, "bin/sh exists=$binShExists, isSymlink=$binShIsLink")

                    if (!isRootfsValid()) {
                        throw RuntimeException(
                            "Rootfs extraction completed ($filesExtracted entries) but /bin/sh not found. " +
                                    "rootfs/=${rootContents}, bin/=${binContents.take(10)}, " +
                                    "tarball=${tarball.length()} bytes"
                        )
                    }
                    Log.d(TAG, "Rootfs extraction complete")
                }

                postSuccess(result, mapOf("ready" to true))
            } catch (e: Exception) {
                Log.e(TAG, "Setup failed", e)
                postSuccess(result, mapOf("error" to true, "message" to (e.message ?: "Setup failed")))
            }
        }
    }

    // ─── Exec ────────────────────────────────────────────────────────────────────

    private fun handleExec(call: MethodCall, result: MethodChannel.Result) {
        val command = call.argument<String>("command") ?: run {
            result.error("INVALID_ARG", "command is required", null)
            return
        }
        val timeoutMs = (call.argument<Number>("timeout_ms") ?: 30000).toLong()
        val workingDir = call.argument<String>("working_dir") ?: "/root"

        executor.execute {
            try {
                val cmd = mutableListOf(
                    prootBin.absolutePath,
                    "-0",
                    "-r", rootfsDir.absolutePath,
                    "-b", "/dev",
                    "-b", "/proc",
                    "-b", "/sys",
                    "-w", workingDir,
                    "/bin/sh", "-c", command,
                )

                val pb = ProcessBuilder(cmd)
                pb.environment()["HOME"] = "/root"
                pb.environment()["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                pb.environment()["TERM"] = "xterm-256color"
                pb.environment()["PYTHONUNBUFFERED"] = "1"
                pb.environment()["PROOT_TMP_DIR"] = sandboxDir.absolutePath
                pb.environment()["PROOT_LOADER"] = loaderBin.absolutePath
                pb.redirectErrorStream(false)

                val process = pb.start()
                activeProcesses.add(process)

                val stdoutFuture = executor.submit<String> { readCapped(process.inputStream, MAX_OUTPUT_BYTES) }
                val stderrFuture = executor.submit<String> { readCapped(process.errorStream, MAX_OUTPUT_BYTES) }

                val finished = process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
                if (!finished) {
                    process.destroyForcibly()
                    process.waitFor(5, TimeUnit.SECONDS)
                }

                activeProcesses.remove(process)

                // Drain reader threads BEFORE closing streams. After the
                // process exits, its pipe ends close → readers see EOF and
                // return promptly. If PRoot lingers (zombie children keeping
                // the pipe open), the 3s timeout fires → we force-close
                // streams to unblock, then retry.
                var stdout = try { stdoutFuture.get(3, TimeUnit.SECONDS) } catch (_: Exception) { null }
                var stderr = try { stderrFuture.get(3, TimeUnit.SECONDS) } catch (_: Exception) { null }

                if (stdout == null || stderr == null) {
                    // Timed out — force-close streams to unblock hung readers.
                    try { process.inputStream.close() } catch (_: Exception) {}
                    try { process.errorStream.close() } catch (_: Exception) {}
                    try { process.outputStream.close() } catch (_: Exception) {}
                    if (stdout == null) stdout = try { stdoutFuture.get(1, TimeUnit.SECONDS) } catch (_: Exception) { "" }
                    if (stderr == null) stderr = try { stderrFuture.get(1, TimeUnit.SECONDS) } catch (_: Exception) { "" }
                } else {
                    try { process.inputStream.close() } catch (_: Exception) {}
                    try { process.errorStream.close() } catch (_: Exception) {}
                    try { process.outputStream.close() } catch (_: Exception) {}
                }

                postSuccess(result, mapOf(
                    "exit_code" to if (finished) process.exitValue() else -1,
                    "stdout" to stdout,
                    "stderr" to stderr,
                    "timed_out" to !finished,
                ))
            } catch (e: Exception) {
                Log.e(TAG, "Exec failed", e)
                postSuccess(result, mapOf("error" to true, "message" to (e.message ?: "Execution failed")))
            }
        }
    }

    // ─── Streaming Exec ────────────────────────────────────────────────────────────

    /**
     * Streaming exec triggered from EventChannel.onListen.
     * Tries PTY first (enables TUI apps: htop, top, vim, etc.).
     * Falls back to plain pipes if PTY allocation fails.
     */
    private fun startStreamingExec(command: String, timeoutMs: Long, workingDir: String) {
        executor.execute {
            val ptyFds = try { PtyHelper.openPty(cols = 220, rows = 50) } catch (_: Exception) { null }
            if (ptyFds != null) {
                execWithPty(command, timeoutMs, workingDir, masterFd = ptyFds[0], slaveFd = ptyFds[1])
            } else {
                Log.w(TAG, "PTY allocation failed, falling back to pipes")
                execWithPipes(command, timeoutMs, workingDir)
            }
        }
    }

    /**
     * PTY-based streaming exec. The subprocess receives a real terminal (isatty() == true),
     * so TUI apps (htop, top, vim, nano, etc.) work correctly and ANSI colours are preserved.
     * All output (stdout + stderr) comes through the PTY master.
     */
    private fun execWithPty(command: String, timeoutMs: Long, workingDir: String, masterFd: Int, slaveFd: Int) {
        try {
            val cmd = mutableListOf(
                prootBin.absolutePath,
                "-0",
                "-r", rootfsDir.absolutePath,
                "-b", "/dev",
                "-b", "/proc",
                "-b", "/sys",
                "-w", workingDir,
                "/bin/sh", "-c", command,
            )

            val pb = ProcessBuilder(cmd)
            pb.environment()["HOME"] = "/root"
            pb.environment()["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            pb.environment()["TERM"] = "xterm-256color"
            pb.environment()["COLUMNS"] = "220"
            pb.environment()["LINES"] = "50"
            pb.environment()["PYTHONUNBUFFERED"] = "1"
            pb.environment()["PROOT_TMP_DIR"] = sandboxDir.absolutePath
            pb.environment()["PROOT_LOADER"] = loaderBin.absolutePath

            // Redirect stdin/stdout/stderr to the PTY slave.
            // /proc/self/fd/<n> is a symlink to the open fd — works reliably on Android.
            val slaveFile = File("/proc/self/fd/$slaveFd")
            pb.redirectInput(slaveFile)
            pb.redirectOutput(slaveFile)
            pb.redirectError(slaveFile)

            val process = pb.start()
            activeProcesses.add(process)
            activePtyMasterFd = masterFd

            // Close the slave end in the parent — the child process has its own copy.
            PtyHelper.closeFd(slaveFd)

            val sink = eventSink
            val buf = ByteArray(4096)

            // Single reader thread: PTY master merges stdout + stderr with ANSI intact.
            val readerThread = Thread {
                try {
                    var n: Int
                    while (PtyHelper.readPty(masterFd, buf).also { n = it } > 0) {
                        val text = String(buf, 0, n, Charsets.UTF_8)
                        mainHandler.post {
                            sink?.success(mapOf("type" to "stdout", "data" to text))
                        }
                    }
                } catch (_: Exception) { }
            }.apply { isDaemon = true; start() }

            val finished = process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!finished) {
                process.destroyForcibly()
                process.waitFor(5, TimeUnit.SECONDS)
            }

            // Closing masterFd signals EIO to the reader thread → it terminates.
            activePtyMasterFd = -1
            PtyHelper.closeFd(masterFd)
            readerThread.join(3000)

            activeProcesses.remove(process)

            val exitCode = if (finished) process.exitValue() else -1
            mainHandler.post {
                sink?.success(mapOf(
                    "type" to "exit",
                    "exit_code" to exitCode,
                    "timed_out" to !finished,
                ))
                sink?.endOfStream()
            }
        } catch (e: Exception) {
            Log.e(TAG, "execWithPty failed", e)
            PtyHelper.closeFd(masterFd)
            PtyHelper.closeFd(slaveFd)
            // Attempt pipe fallback so the user still gets a result.
            execWithPipes(command, timeoutMs, workingDir)
        }
    }

    /**
     * Pipe-based streaming exec fallback (used when PTY allocation fails).
     * stdout and stderr are captured on separate threads and emitted independently.
     */
    private fun execWithPipes(command: String, timeoutMs: Long, workingDir: String) {
        try {
            val cmd = mutableListOf(
                prootBin.absolutePath,
                "-0",
                "-r", rootfsDir.absolutePath,
                "-b", "/dev",
                "-b", "/proc",
                "-b", "/sys",
                "-w", workingDir,
                "/bin/sh", "-c", command,
            )

            val pb = ProcessBuilder(cmd)
            pb.environment()["HOME"] = "/root"
            pb.environment()["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            pb.environment()["TERM"] = "xterm-256color"
            pb.environment()["PYTHONUNBUFFERED"] = "1"
            pb.environment()["PROOT_TMP_DIR"] = sandboxDir.absolutePath
            pb.environment()["PROOT_LOADER"] = loaderBin.absolutePath
            pb.redirectErrorStream(false)

            val process = pb.start()
            activeProcesses.add(process)

            val sink = eventSink

            val stdoutThread = Thread {
                try {
                    val reader = BufferedReader(InputStreamReader(process.inputStream))
                    val buf = CharArray(4096)
                    var read: Int
                    while (reader.read(buf).also { read = it } != -1) {
                        val text = String(buf, 0, read)
                        mainHandler.post { sink?.success(mapOf("type" to "stdout", "data" to text)) }
                    }
                } catch (_: Exception) { }
            }.apply { isDaemon = true; start() }

            val stderrThread = Thread {
                try {
                    val reader = BufferedReader(InputStreamReader(process.errorStream))
                    val buf = CharArray(4096)
                    var read: Int
                    while (reader.read(buf).also { read = it } != -1) {
                        val text = String(buf, 0, read)
                        mainHandler.post { sink?.success(mapOf("type" to "stderr", "data" to text)) }
                    }
                } catch (_: Exception) { }
            }.apply { isDaemon = true; start() }

            val finished = process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            if (!finished) {
                process.destroyForcibly()
                process.waitFor(5, TimeUnit.SECONDS)
            }

            try { process.inputStream.close() } catch (_: Exception) {}
            try { process.errorStream.close() } catch (_: Exception) {}
            try { process.outputStream.close() } catch (_: Exception) {}

            stdoutThread.join(3000)
            stderrThread.join(3000)

            activeProcesses.remove(process)

            val exitCode = if (finished) process.exitValue() else -1
            mainHandler.post {
                sink?.success(mapOf(
                    "type" to "exit",
                    "exit_code" to exitCode,
                    "timed_out" to !finished,
                ))
                sink?.endOfStream()
            }
        } catch (e: Exception) {
            Log.e(TAG, "execWithPipes failed", e)
            mainHandler.post {
                eventSink?.success(mapOf(
                    "type" to "exit",
                    "exit_code" to -1,
                    "timed_out" to false,
                    "error" to (e.message ?: "Execution failed"),
                ))
                eventSink?.endOfStream()
            }
        }
    }

    // ─── Write Stdin ──────────────────────────────────────────────────────────────

    private fun handleWriteStdin(call: MethodCall, result: MethodChannel.Result) {
        val data = call.argument<String>("data")
        if (data.isNullOrEmpty()) {
            result.success(mapOf("error" to true, "message" to "data is required"))
            return
        }
        val bytes = data.toByteArray(Charsets.UTF_8)
        try {
            val ptyFd = activePtyMasterFd
            if (ptyFd >= 0) {
                // PTY mode: write to PTY master fd
                PtyHelper.writePty(ptyFd, bytes, bytes.size)
                result.success(mapOf("written" to bytes.size))
            } else {
                // Pipe mode: write to process stdin
                val process = activeProcesses.lastOrNull()
                if (process == null) {
                    result.success(mapOf("error" to true, "message" to "No active process"))
                    return
                }
                process.outputStream.write(bytes)
                process.outputStream.flush()
                result.success(mapOf("written" to bytes.size))
            }
        } catch (e: Exception) {
            result.success(mapOf("error" to true, "message" to "Write failed: ${e.message}"))
        }
    }

    // ─── Kill ─────────────────────────────────────────────────────────────────────

    private fun handleKill(result: MethodChannel.Result) {
        var killed = 0
        for (p in activeProcesses) {
            p.destroyForcibly()
            killed++
        }
        activeProcesses.clear()
        result.success(mapOf("killed" to true, "count" to killed))
    }

    // ─── Tar.gz extraction (pure Kotlin, no system `tar` needed) ─────────────────

    /**
     * Extract a .tar.gz archive to [destDir].
     *
     * Handles regular files, directories, symlinks, and hardlinks.
     * Uses POSIX ustar / GNU tar long name extensions.
     */
    private fun extractTarGz(tarGz: File, destDir: File): Int {
        return GZIPInputStream(tarGz.inputStream().buffered()).use { gzis ->
            extractTar(gzis, destDir)
        }
    }

    private fun extractTar(input: InputStream, destDir: File): Int {
        val header = ByteArray(TAR_BLOCK_SIZE)
        var longName: String? = null
        var longLink: String? = null
        var entriesExtracted = 0

        while (true) {
            val bytesRead = readFully(input, header)
            if (bytesRead < TAR_BLOCK_SIZE) break

            // Two consecutive zero blocks signal end of archive
            if (header.all { it == 0.toByte() }) {
                val nextBlock = ByteArray(TAR_BLOCK_SIZE)
                readFully(input, nextBlock)
                break
            }

            val name = longName ?: readTarString(header, 0, 100)
            val linkName = longLink ?: readTarString(header, 157, 100)
            longName = null
            longLink = null

            val typeFlag = header[156].toInt().toChar()
            val sizeStr = readTarString(header, 124, 12).trim()
            val size = if (sizeStr.isNotEmpty()) sizeStr.toLong(8) else 0L
            val modeStr = readTarString(header, 100, 8).trim()
            val mode = if (modeStr.isNotEmpty()) modeStr.toInt(8) else 0

            // POSIX ustar prefix
            val prefix = readTarString(header, 345, 155)
            val fullName = if (prefix.isNotEmpty()) "$prefix/$name" else name

            // GNU long name / long link extensions
            if (typeFlag == 'L') {
                longName = readTarData(input, size).toString(Charsets.UTF_8).trimEnd('\u0000')
                continue
            }
            if (typeFlag == 'K') {
                longLink = readTarData(input, size).toString(Charsets.UTF_8).trimEnd('\u0000')
                continue
            }

            if (fullName.isEmpty() || fullName == "." || fullName == "./") {
                skipTarData(input, size)
                continue
            }

            val destFile = File(destDir, fullName)

            // Security: prevent path traversal
            if (!destFile.canonicalPath.startsWith(destDir.canonicalPath)) {
                Log.w(TAG, "Skipping path traversal entry: $fullName")
                skipTarData(input, size)
                continue
            }

            when (typeFlag) {
                '5', 'D' -> {
                    // Directory
                    destFile.mkdirs()
                    skipTarData(input, size)
                }
                '2' -> {
                    // Symlink
                    destFile.parentFile?.mkdirs()
                    destFile.delete()
                    try {
                        java.nio.file.Files.createSymbolicLink(
                            destFile.toPath(),
                            java.nio.file.Paths.get(linkName)
                        )
                        entriesExtracted++
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to create symlink $fullName -> $linkName: ${e.message}")
                        // Fallback: if symlink target is a file in the same rootfs, try copying
                        val resolvedTarget = if (linkName.startsWith("/")) {
                            File(destDir, linkName)
                        } else {
                            File(destFile.parentFile, linkName)
                        }
                        if (resolvedTarget.exists()) {
                            try {
                                resolvedTarget.copyTo(destFile, overwrite = true)
                                if (resolvedTarget.canExecute()) destFile.setExecutable(true, false)
                                entriesExtracted++
                                Log.d(TAG, "Fallback: copied $fullName from ${resolvedTarget.path}")
                            } catch (copyErr: Exception) {
                                Log.e(TAG, "Fallback copy also failed for $fullName: ${copyErr.message}")
                            }
                        }
                    }
                    skipTarData(input, size)
                }
                '1' -> {
                    // Hardlink — create as a copy on Android (real hardlinks may not work)
                    destFile.parentFile?.mkdirs()
                    val linkTarget = File(destDir, linkName)
                    if (linkTarget.exists()) {
                        linkTarget.copyTo(destFile, overwrite = true)
                    }
                    skipTarData(input, size)
                }
                '0', '\u0000' -> {
                    // Regular file
                    destFile.parentFile?.mkdirs()
                    FileOutputStream(destFile).use { fos ->
                        var remaining = size
                        val buf = ByteArray(8192)
                        while (remaining > 0) {
                            val toRead = minOf(buf.size.toLong(), remaining).toInt()
                            val n = input.read(buf, 0, toRead)
                            if (n <= 0) break
                            fos.write(buf, 0, n)
                            remaining -= n
                        }
                    }
                    // Skip padding to next 512-byte boundary
                    val padding = (TAR_BLOCK_SIZE - (size % TAR_BLOCK_SIZE)) % TAR_BLOCK_SIZE
                    if (padding > 0) input.skip(padding)

                    // Set executable permission if any exec bit is set
                    if (mode and 0b001_001_001 != 0) {
                        destFile.setExecutable(true, false)
                    }
                    entriesExtracted++
                }
                else -> {
                    // Unknown type, skip
                    skipTarData(input, size)
                }
            }
        }

        Log.d(TAG, "Extracted $entriesExtracted files")
        return entriesExtracted
    }

    private fun readFully(input: InputStream, buf: ByteArray): Int {
        var offset = 0
        while (offset < buf.size) {
            val n = input.read(buf, offset, buf.size - offset)
            if (n <= 0) break
            offset += n
        }
        return offset
    }

    private fun readTarString(header: ByteArray, offset: Int, length: Int): String {
        val end = minOf(offset + length, header.size)
        val nullPos = header.indexOf(0.toByte(), offset).let { if (it in offset until end) it else end }
        return String(header, offset, nullPos - offset, Charsets.UTF_8)
    }

    private fun readTarData(input: InputStream, size: Long): ByteArray {
        val data = ByteArray(size.toInt())
        var offset = 0
        while (offset < data.size) {
            val n = input.read(data, offset, data.size - offset)
            if (n <= 0) break
            offset += n
        }
        val padding = (TAR_BLOCK_SIZE - (size % TAR_BLOCK_SIZE)) % TAR_BLOCK_SIZE
        if (padding > 0) input.skip(padding)
        return data
    }

    private fun skipTarData(input: InputStream, size: Long) {
        val total = size + (TAR_BLOCK_SIZE - (size % TAR_BLOCK_SIZE)) % TAR_BLOCK_SIZE
        var remaining = total
        while (remaining > 0) {
            val skipped = input.skip(remaining)
            if (skipped <= 0) break
            remaining -= skipped
        }
    }

    private fun ByteArray.indexOf(byte: Byte, fromIndex: Int): Int {
        for (i in fromIndex until size) {
            if (this[i] == byte) return i
        }
        return -1
    }

    // ─── Post-extraction fixups ─────────────────────────────────────────────────

    /**
     * Ensure /bin/sh exists in the rootfs. Alpine's /bin/sh is a symlink to
     * busybox, but symlink creation can silently fail on some Android devices
     * (SELinux, filesystem limitations). If the symlink is missing, we:
     * 1. Try creating it again
     * 2. Fall back to a hard copy of busybox
     * 3. Fall back to a wrapper script
     */
    private fun ensureBinSh() {
        val binDir = File(rootfsDir, "bin")
        val binSh = File(binDir, "sh")
        val busybox = File(binDir, "busybox")

        if (binSh.exists()) {
            Log.d(TAG, "/bin/sh already exists")
            return
        }

        Log.w(TAG, "/bin/sh missing after extraction, attempting fixups...")

        // Attempt 1: recreate symlink
        if (busybox.exists()) {
            try {
                java.nio.file.Files.createSymbolicLink(
                    binSh.toPath(),
                    java.nio.file.Paths.get("busybox")
                )
                Log.d(TAG, "Created symlink /bin/sh -> busybox")
                return
            } catch (e: Exception) {
                Log.w(TAG, "Symlink creation failed: ${e.message}")
            }

            // Attempt 2: hard copy of busybox as sh
            try {
                busybox.copyTo(binSh, overwrite = true)
                binSh.setExecutable(true, false)
                Log.d(TAG, "Copied busybox -> /bin/sh")
                return
            } catch (e: Exception) {
                Log.w(TAG, "Copy failed: ${e.message}")
            }
        }

        // Attempt 3: create a minimal wrapper script
        try {
            binSh.writeText("#!/bin/busybox sh\nexec /bin/busybox sh \"\$@\"\n")
            binSh.setExecutable(true, false)
            Log.d(TAG, "Created wrapper script for /bin/sh")
        } catch (e: Exception) {
            Log.e(TAG, "All /bin/sh fixup attempts failed: ${e.message}")
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────────

    private fun postSuccess(result: MethodChannel.Result, data: Map<String, Any?>) {
        mainHandler.post { result.success(data) }
    }

    private fun detectAbi(): String {
        val abis = android.os.Build.SUPPORTED_ABIS
        for (abi in abis) {
            if (ALPINE_URLS.containsKey(abi)) return abi
        }
        return abis.firstOrNull() ?: "arm64-v8a"
    }

    private fun downloadFile(urlStr: String, dest: File) {
        val conn = URL(urlStr).openConnection() as HttpURLConnection
        conn.connectTimeout = 30_000
        conn.readTimeout = 60_000
        try {
            conn.inputStream.use { input ->
                dest.outputStream().use { output ->
                    input.copyTo(output, bufferSize = 8192)
                }
            }
        } finally {
            conn.disconnect()
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(8192)
            var read: Int
            while (input.read(buffer).also { read = it } != -1) {
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun readCapped(stream: InputStream, maxBytes: Int): String {
        val sb = StringBuilder()
        val reader = BufferedReader(InputStreamReader(stream))
        var totalBytes = 0
        var truncated = false
        val buffer = CharArray(4096)
        var read: Int

        while (reader.read(buffer).also { read = it } != -1) {
            val byteEstimate = totalBytes + read * 2
            if (byteEstimate > maxBytes) {
                val remaining = (maxBytes - totalBytes) / 2
                if (remaining > 0) {
                    sb.append(buffer, 0, remaining)
                }
                truncated = true
                break
            }
            sb.append(buffer, 0, read)
            totalBytes += read * 2
        }

        if (truncated) {
            sb.append("\n[truncated — output exceeded ${maxBytes / 1024}KB]")
        }
        return sb.toString()
    }
}
