/// Web tools for FlutterClaw: search and fetch.
///
/// WebSearchTool: DuckDuckGo HTML scraping by default; Brave/Tavily/Perplexity via API when configured.
/// WebFetchTool: Fetches URL content and converts to markdown.
library;

import 'package:dio/dio.dart';
import 'package:flutterclaw/data/models/config.dart';
import 'package:flutterclaw/services/ssrf_guard.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

import 'registry.dart';

/// Web search tool. Uses configured provider (DuckDuckGo by default).
class WebSearchTool extends Tool {
  final FlutterClawConfig? config;
  final Dio _dio = Dio();

  WebSearchTool({this.config});

  @override
  String get name => 'web_search';

  @override
  String get description =>
      'Search the web for information. Returns a list of results with titles and snippets.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'Search query.',
          },
          'count': {
            'type': 'integer',
            'description': 'Maximum number of results to return (default 5).',
          },
        },
        'required': ['query'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final query = args['query'] as String?;
    if (query == null || query.isEmpty) {
      return ToolResult.error('query is required');
    }
    final count = args['count'] as int? ?? 5;

    final web = config?.tools.web ?? const WebToolsConfig();
    final maxResults = count.clamp(1, 20);

    // Try API providers first if configured
    if (web.brave.enabled && web.brave.apiKey != null) {
      return _searchBrave(query, maxResults, web.brave);
    }
    if (web.tavily.enabled && web.tavily.apiKey != null) {
      return _searchTavily(query, maxResults, web.tavily);
    }
    if (web.perplexity.enabled && web.perplexity.apiKey != null) {
      return _searchPerplexity(query, maxResults, web.perplexity);
    }

    // Default: DuckDuckGo HTML scraping
    if (web.duckduckgo.enabled) {
      return _searchDuckDuckGo(query, maxResults);
    }

    return ToolResult.error('No web search provider configured');
  }

  Future<ToolResult> _searchDuckDuckGo(String query, int count) async {
    try {
      final encoded = Uri.encodeComponent(query);
      final url = 'https://html.duckduckgo.com/html/?q=$encoded';
      final response = await _dio.get<String>(
        url,
        options: Options(
          headers: {
            'User-Agent':
                'Mozilla/5.0 (compatible; FlutterClaw/1.0; +https://flutterclaw.ai)',
          },
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s < 400,
        ),
      );

      if (response.data == null || response.statusCode != 200) {
        return ToolResult.error('DuckDuckGo search failed');
      }

      final document = html_parser.parse(response.data);
      final results = <String>[];
      final links = document.querySelectorAll('.result__a');
      var i = 0;
      for (final link in links) {
        if (i >= count) break;
        final href = link.attributes['href'];
        final title = link.text.trim();
        if (title.isEmpty || href == null) continue;
        var snippet = '';
        var parent = link.parent;
        while (parent != null) {
          if (parent.classes.contains('result')) {
            final snippetEl = parent.querySelector('.result__snippet');
            if (snippetEl != null) {
              snippet = snippetEl.text.trim();
            }
            break;
          }
          parent = parent.parent;
        }
        results.add('${i + 1}. $title\n   $href\n   $snippet');
        i++;
      }

      if (results.isEmpty) {
        return ToolResult.success('No results found for: $query');
      }
      return ToolResult.success(results.join('\n\n'));
    } catch (e) {
      return ToolResult.error('Web search failed: $e');
    }
  }

  Future<ToolResult> _searchBrave(
    String query,
    int count,
    WebSearchProviderConfig cfg,
  ) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://api.search.brave.com/res/v1/web/search',
        queryParameters: {'q': query, 'count': count},
        options: Options(
          headers: {'X-Subscription-Token': cfg.apiKey!},
          validateStatus: (s) => s != null && s < 400,
        ),
      );

      if (response.data == null) {
        return ToolResult.error('Brave search API failed');
      }

      final web = response.data!['web'] as Map<String, dynamic>?;
      final results = (web?['results'] as List<dynamic>?) ?? [];
      final lines = results.asMap().entries.map((e) {
        final r = e.value as Map<String, dynamic>;
        final i = e.key + 1;
        final title = r['title'] as String? ?? '';
        final url = r['url'] as String? ?? '';
        final desc = r['description'] as String? ?? '';
        return '$i. $title\n   $url\n   $desc';
      });
      return ToolResult.success(
        lines.isEmpty ? 'No results found for: $query' : lines.join('\n\n'),
      );
    } catch (e) {
      return ToolResult.error('Brave search failed: $e');
    }
  }

  Future<ToolResult> _searchTavily(
    String query,
    int count,
    WebSearchProviderConfig cfg,
  ) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        'https://api.tavily.com/search',
        data: {
          'api_key': cfg.apiKey,
          'query': query,
          'max_results': count,
        },
        options: Options(validateStatus: (s) => s != null && s < 400),
      );

      if (response.data == null) {
        return ToolResult.error('Tavily search API failed');
      }

      final results = (response.data!['results'] as List<dynamic>?) ?? [];
      final lines = results.asMap().entries.map((e) {
        final r = e.value as Map<String, dynamic>;
        final i = e.key + 1;
        final title = r['title'] as String? ?? '';
        final url = r['url'] as String? ?? '';
        final content = r['content'] as String? ?? '';
        return '$i. $title\n   $url\n   $content';
      });
      return ToolResult.success(
        lines.isEmpty ? 'No results found for: $query' : lines.join('\n\n'),
      );
    } catch (e) {
      return ToolResult.error('Tavily search failed: $e');
    }
  }

  Future<ToolResult> _searchPerplexity(
    String query,
    int count,
    WebSearchProviderConfig cfg,
  ) async {
    // Perplexity API would require their chat/search endpoint
    // Stub for now - could use sonar API with search
    return ToolResult.error(
      'Perplexity search not yet implemented. Use DuckDuckGo or Brave.',
    );
  }
}

/// Fetches URL content and converts to markdown-like text.
class WebFetchTool extends Tool {
  final Dio _dio = Dio();

  /// Optional headless browser for JS-rendered pages.
  Tool? headlessBrowser;

  WebFetchTool({this.headlessBrowser});

  @override
  String get name => 'web_fetch';

  @override
  String get description =>
      'Fetch the content of a URL and convert to markdown. Useful for reading web pages. '
      'Set headless=true to use a full browser engine for JS-heavy/SPA pages.';

  @override
  Map<String, dynamic> get parameters => {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': 'URL to fetch.',
          },
          'max_chars': {
            'type': 'integer',
            'description': 'Maximum characters to return (default 50000).',
          },
          'headless': {
            'type': 'boolean',
            'description':
                'Use headless browser with JS support (default: false). '
                'Slower but works with SPAs and JS-rendered content. '
                'Auto-enabled when static fetch yields little content.',
          },
        },
        'required': ['url'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args) async {
    final urlStr = args['url'] as String?;
    if (urlStr == null || urlStr.isEmpty) {
      return ToolResult.error('url is required');
    }
    final maxChars = args['max_chars'] as int? ?? 50000;
    final forceHeadless = args['headless'] as bool? ?? false;

    if (forceHeadless && headlessBrowser != null) {
      return _fetchHeadless(urlStr, maxChars);
    }

    Uri uri;
    try {
      uri = Uri.parse(urlStr);
      if (!uri.hasScheme) {
        uri = Uri.parse('https://$urlStr');
      }
    } catch (_) {
      return ToolResult.error('Invalid URL: $urlStr');
    }

    final ssrfError = validateFetchUrl(uri.toString());
    if (ssrfError != null) return ToolResult.error(ssrfError);

    try {
      final response = await _dio.get<String>(
        uri.toString(),
        options: Options(
          headers: {
            'User-Agent':
                'Mozilla/5.0 (compatible; FlutterClaw/1.0; +https://flutterclaw.ai)',
          },
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s < 400,
          receiveTimeout: const Duration(seconds: 30),
        ),
      );

      if (response.data == null || response.statusCode != 200) {
        return ToolResult.error(
          'Failed to fetch: ${response.statusCode ?? 'unknown'}',
        );
      }

      final document = html_parser.parse(response.data);
      _removeScriptsAndStyles(document);
      final text = _htmlToMarkdown(document);

      // Auto-fallback to headless browser if static content is too thin
      if (text.trim().length < 200 && headlessBrowser != null) {
        return _fetchHeadless(urlStr, maxChars);
      }

      final truncated = text.length > maxChars
          ? '${text.substring(0, maxChars)}\n\n[... truncated]'
          : text;
      return ToolResult.success(truncated);
    } catch (e) {
      return ToolResult.error('Fetch failed: $e');
    }
  }

  Future<ToolResult> _fetchHeadless(String url, int maxChars) async {
    // Use the headless browser tool to navigate and extract content.
    // Do NOT close the session — preserves cookies and session state for
    // subsequent calls (login sessions, CAPTCHA completions, etc.).
    await headlessBrowser!.execute({'action': 'navigate', 'url': url});
    return headlessBrowser!.execute({
      'action': 'get_content',
      'max_chars': maxChars,
    });
  }

  void _removeScriptsAndStyles(dom.Document document) {
    for (final tag in document.querySelectorAll('script, style, noscript')) {
      tag.remove();
    }
  }

  String _htmlToMarkdown(dom.Document document) {
    final buffer = StringBuffer();
    final body = document.body ?? document.documentElement;
    if (body == null) return '';

    void visit(dom.Node node) {
      if (node is dom.Element) {
        switch (node.localName?.toLowerCase()) {
          case 'h1':
            buffer.writeln('# ${_textContent(node)}');
            return;
          case 'h2':
            buffer.writeln('## ${_textContent(node)}');
            return;
          case 'h3':
            buffer.writeln('### ${_textContent(node)}');
            return;
          case 'h4':
            buffer.writeln('#### ${_textContent(node)}');
            return;
          case 'h5':
            buffer.writeln('##### ${_textContent(node)}');
            return;
          case 'h6':
            buffer.writeln('###### ${_textContent(node)}');
            return;
          case 'p':
          case 'div':
            for (final child in node.nodes) visit(child);
            buffer.writeln();
            return;
          case 'br':
            buffer.writeln();
            return;
          case 'a':
            final href = node.attributes['href'];
            final text = _textContent(node);
            if (href != null && href.isNotEmpty) {
              buffer.write('[$text]($href)');
            } else {
              buffer.write(text);
            }
            return;
          case 'li':
            buffer.write('- ');
            for (final child in node.nodes) visit(child);
            buffer.writeln();
            return;
          case 'ul':
          case 'ol':
            for (final child in node.nodes) visit(child);
            buffer.writeln();
            return;
          default:
            for (final child in node.nodes) visit(child);
            return;
        }
      }
      if (node is dom.Text) {
        buffer.write(node.text);
      }
    }

    visit(body);
    return buffer.toString().trim();
  }

  String _textContent(dom.Element el) {
    return el.text.trim();
  }
}
