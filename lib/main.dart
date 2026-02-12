import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StreamPlayerApp());
}

class StreamPlayerApp extends StatelessWidget {
  const StreamPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stream Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const PlayerScreen(),
    );
  }
}

// Subtitle cue model
class SubtitleCue {
  final Duration start;
  final Duration end;
  final String text;

  SubtitleCue({required this.start, required this.end, required this.text});
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _controller;
  bool _isLoading = true;
  bool _hasError = false;
  String _errorMessage = '';
  bool _showControls = true;
  bool _isPlaying = false;

  // Subtitle state
  List<SubtitleCue> _subtitles = [];
  bool _subtitlesEnabled = true;
  String _currentSubtitle = '';

  // Get URL from query parameters
  String? get _videoUrl {
    final uri = Uri.parse(html.window.location.href);
    return uri.queryParameters['url'];
  }

  // Get subtitle URL from query parameters
  String? get _subtitleUrl {
    final uri = Uri.parse(html.window.location.href);
    return uri.queryParameters['sub'];
  }

  // Get proxy server URL
  String? get _proxyServer {
    final uri = Uri.parse(html.window.location.href);
    return uri.queryParameters['proxy'];
  }

  // Build the final URL (with proxy if specified)
  String? get _finalUrl {
    final url = _videoUrl;
    final proxy = _proxyServer;

    if (url == null) return null;

    if (proxy != null && proxy.isNotEmpty) {
      return '$proxy/proxy?url=${Uri.encodeComponent(url)}';
    }
    return url;
  }

  // Build subtitle URL (with proxy if specified)
  String? get _finalSubtitleUrl {
    final url = _subtitleUrl;
    final proxy = _proxyServer;

    if (url == null) return null;

    if (proxy != null && proxy.isNotEmpty) {
      return '$proxy/proxy?url=${Uri.encodeComponent(url)}';
    }
    return url;
  }

  @override
  void initState() {
    super.initState();
    _initializePlayer();
    _setupKeyboardListener();
  }

  void _setupKeyboardListener() {
    html.window.onKeyDown.listen((event) {
      _handleKeyPress(event.keyCode);
    });
  }

  void _handleKeyPress(int keyCode) {
    setState(() => _showControls = true);
    _hideControlsDelayed();

    switch (keyCode) {
      case 13: // Enter / OK
      case 32: // Space
        _togglePlayPause();
        break;
      case 37: // Left Arrow
        _seek(-10);
        break;
      case 39: // Right Arrow
        _seek(10);
        break;
      case 38: // Up Arrow
        _setVolume(0.1);
        break;
      case 40: // Down Arrow
        _setVolume(-0.1);
        break;
      case 67: // 'C' key - toggle subtitles
        _toggleSubtitles();
        break;
      case 415: // Media Play
        _controller?.play();
        break;
      case 19: // Media Pause
        _controller?.pause();
        break;
      case 179: // Media Play/Pause
        _togglePlayPause();
        break;
      case 227: // Fast Forward
        _seek(30);
        break;
      case 228: // Rewind
        _seek(-30);
        break;
    }
  }

  void _togglePlayPause() {
    if (_controller == null) return;
    if (_controller!.value.isPlaying) {
      _controller!.pause();
    } else {
      _controller!.play();
      _hideControlsDelayed();
    }
  }

  void _toggleSubtitles() {
    setState(() {
      _subtitlesEnabled = !_subtitlesEnabled;
    });
  }

  void _seek(int seconds) {
    if (_controller == null) return;
    final currentPosition = _controller!.value.position;
    final newPosition = currentPosition + Duration(seconds: seconds);
    _controller!.seekTo(newPosition);
  }

  void _setVolume(double delta) {
    if (_controller == null) return;
    final currentVolume = _controller!.value.volume;
    final newVolume = (currentVolume + delta).clamp(0.0, 1.0);
    _controller!.setVolume(newVolume);
  }

  Future<void> _initializePlayer() async {
    final url = _finalUrl;

    if (url == null || url.isEmpty) {
      setState(() {
        _hasError = true;
        _errorMessage = 'No video URL provided. Use ?url=<stream_url>';
        _isLoading = false;
      });
      return;
    }

    debugPrint('[Player] Initializing with URL: $url');

    try {
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: false,
          allowBackgroundPlayback: false,
        ),
      );

      await _controller!.initialize();

      _controller!.addListener(_videoListener);

      // Load subtitles if provided
      await _loadSubtitles();

      setState(() {
        _isLoading = false;
        _isPlaying = false;
        _showControls = true;
      });

      debugPrint('[Player] Initialized successfully');
      debugPrint('[Player] Duration: ${_controller!.value.duration}');
    } catch (e) {
      debugPrint('[Player] Error: $e');
      setState(() {
        _hasError = true;
        _errorMessage = 'Failed to load video: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _loadSubtitles() async {
    final subUrl = _finalSubtitleUrl;
    if (subUrl == null || subUrl.isEmpty) {
      debugPrint('[Subtitles] No subtitle URL provided');
      return;
    }

    debugPrint('[Subtitles] Loading from: $subUrl');

    try {
      final response = await http.get(Uri.parse(subUrl));
      if (response.statusCode == 200) {
        _subtitles = _parseSubtitles(response.body);
        debugPrint('[Subtitles] Loaded ${_subtitles.length} cues');
      } else {
        debugPrint('[Subtitles] Failed to load: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[Subtitles] Error loading: $e');
    }
  }

  List<SubtitleCue> _parseSubtitles(String content) {
    // Detect format and parse accordingly
    if (content.contains('WEBVTT')) {
      return _parseVtt(content);
    } else {
      return _parseSrt(content);
    }
  }

  List<SubtitleCue> _parseVtt(String content) {
    final cues = <SubtitleCue>[];
    final lines = content.split('\n');

    int i = 0;
    // Skip header
    while (i < lines.length && !lines[i].contains('-->')) {
      i++;
    }

    while (i < lines.length) {
      final line = lines[i].trim();

      if (line.contains('-->')) {
        final times = line.split('-->');
        if (times.length == 2) {
          final start = _parseTimestamp(times[0].trim());
          final end = _parseTimestamp(times[1].trim().split(' ')[0]);

          // Collect text lines
          final textLines = <String>[];
          i++;
          while (i < lines.length && lines[i].trim().isNotEmpty) {
            textLines.add(lines[i].trim());
            i++;
          }

          if (textLines.isNotEmpty) {
            cues.add(SubtitleCue(
              start: start,
              end: end,
              text: _cleanSubtitleText(textLines.join('\n')),
            ));
          }
        }
      }
      i++;
    }

    return cues;
  }

  List<SubtitleCue> _parseSrt(String content) {
    final cues = <SubtitleCue>[];
    final blocks = content.split(RegExp(r'\n\s*\n'));

    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.length < 3) continue;

      // Find the timestamp line
      int timeLineIndex = -1;
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].contains('-->')) {
          timeLineIndex = i;
          break;
        }
      }

      if (timeLineIndex == -1) continue;

      final times = lines[timeLineIndex].split('-->');
      if (times.length == 2) {
        final start = _parseTimestamp(times[0].trim());
        final end = _parseTimestamp(times[1].trim());

        final textLines = lines.sublist(timeLineIndex + 1);
        if (textLines.isNotEmpty) {
          cues.add(SubtitleCue(
            start: start,
            end: end,
            text: _cleanSubtitleText(textLines.join('\n')),
          ));
        }
      }
    }

    return cues;
  }

  Duration _parseTimestamp(String timestamp) {
    // Handle both VTT (00:00:00.000) and SRT (00:00:00,000) formats
    timestamp = timestamp.replaceAll(',', '.');

    final parts = timestamp.split(':');
    if (parts.length == 3) {
      final hours = int.tryParse(parts[0]) ?? 0;
      final minutes = int.tryParse(parts[1]) ?? 0;
      final secondsParts = parts[2].split('.');
      final seconds = int.tryParse(secondsParts[0]) ?? 0;
      final milliseconds =
          secondsParts.length > 1 ? int.tryParse(secondsParts[1].padRight(3, '0').substring(0, 3)) ?? 0 : 0;

      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: milliseconds,
      );
    } else if (parts.length == 2) {
      final minutes = int.tryParse(parts[0]) ?? 0;
      final secondsParts = parts[1].split('.');
      final seconds = int.tryParse(secondsParts[0]) ?? 0;
      final milliseconds =
          secondsParts.length > 1 ? int.tryParse(secondsParts[1].padRight(3, '0').substring(0, 3)) ?? 0 : 0;

      return Duration(
        minutes: minutes,
        seconds: seconds,
        milliseconds: milliseconds,
      );
    }

    return Duration.zero;
  }

  String _cleanSubtitleText(String text) {
    // Remove HTML tags and formatting
    return text
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\{[^}]*\}'), '')
        .trim();
  }

  void _updateCurrentSubtitle() {
    if (_subtitles.isEmpty || _controller == null) {
      _currentSubtitle = '';
      return;
    }

    final position = _controller!.value.position;
    String newSubtitle = '';

    for (final cue in _subtitles) {
      if (position >= cue.start && position <= cue.end) {
        newSubtitle = cue.text;
        break;
      }
    }

    if (newSubtitle != _currentSubtitle) {
      setState(() {
        _currentSubtitle = newSubtitle;
      });
    }
  }

  void _videoListener() {
    if (_controller == null) return;

    final isPlaying = _controller!.value.isPlaying;
    if (isPlaying != _isPlaying) {
      setState(() => _isPlaying = isPlaying);
    }

    // Update subtitles
    _updateCurrentSubtitle();

    if (_controller!.value.hasError) {
      setState(() {
        _hasError = true;
        _errorMessage = _controller!.value.errorDescription ?? 'Unknown error';
      });
    }
  }

  void _hideControlsDelayed() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  @override
  void dispose() {
    _controller?.removeListener(_videoListener);
    _controller?.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: (_) {
          setState(() => _showControls = true);
          _hideControlsDelayed();
        },
        child: GestureDetector(
          onTap: () {
            setState(() => _showControls = !_showControls);
            if (_showControls) _hideControlsDelayed();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Video Player
              if (_controller != null && _controller!.value.isInitialized)
                Center(
                  child: AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: VideoPlayer(_controller!),
                  ),
                ),

              // Subtitles
              if (_subtitlesEnabled && _currentSubtitle.isNotEmpty)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: _showControls ? 140 : 48,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _currentSubtitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),

              // Loading Indicator
              if (_isLoading)
                const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 16),
                      Text(
                        'Loading...',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),

              // Buffering Indicator
              if (_controller != null && _controller!.value.isBuffering)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white54),
                ),

              // Error Message
              if (_hasError)
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    margin: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.white, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          _errorMessage,
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),

              // Controls Overlay
              if (_showControls && _controller != null && _controller!.value.isInitialized)
                _buildControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    final position = _controller!.value.position;
    final duration = _controller!.value.duration;
    final progress = duration.inMilliseconds > 0 ? position.inMilliseconds / duration.inMilliseconds : 0.0;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black54,
            Colors.transparent,
            Colors.transparent,
            Colors.black87,
          ],
          stops: [0.0, 0.2, 0.7, 1.0],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Progress Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Text(
                  _formatDuration(position),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                      activeTrackColor: Colors.red,
                      inactiveTrackColor: Colors.white30,
                      thumbColor: Colors.red,
                      overlayColor: Colors.red.withValues(alpha: 0.3),
                    ),
                    child: Slider(
                      value: progress.clamp(0.0, 1.0),
                      onChanged: (value) {
                        final newPosition = Duration(
                          milliseconds: (value * duration.inMilliseconds).round(),
                        );
                        _controller!.seekTo(newPosition);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _formatDuration(duration),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ),

          // Control Buttons
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Subtitle toggle
                if (_subtitles.isNotEmpty)
                  IconButton(
                    onPressed: _toggleSubtitles,
                    icon: Icon(_subtitlesEnabled ? Icons.subtitles : Icons.subtitles_off),
                    iconSize: 32,
                    color: _subtitlesEnabled ? Colors.white : Colors.white54,
                    tooltip: 'Toggle subtitles (C)',
                  ),
                if (_subtitles.isNotEmpty) const SizedBox(width: 24),

                // Rewind
                IconButton(
                  onPressed: () => _seek(-10),
                  icon: const Icon(Icons.replay_10),
                  iconSize: 40,
                  color: Colors.white,
                ),
                const SizedBox(width: 32),
                // Play/Pause
                IconButton(
                  onPressed: _togglePlayPause,
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  iconSize: 64,
                  color: Colors.white,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white24,
                  ),
                ),
                const SizedBox(width: 32),
                // Forward
                IconButton(
                  onPressed: () => _seek(10),
                  icon: const Icon(Icons.forward_10),
                  iconSize: 40,
                  color: Colors.white,
                ),

                // Spacer to balance subtitle button
                if (_subtitles.isNotEmpty) const SizedBox(width: 24),
                if (_subtitles.isNotEmpty)
                  const SizedBox(width: 32), // Same width as subtitle button
              ],
            ),
          ),
        ],
      ),
    );
  }
}
