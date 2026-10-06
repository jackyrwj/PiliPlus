import 'dart:async';

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/pages/follow_feed/controller.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 关注流的横屏全屏模式：与竖屏共用同一个播放器，上下滑照样切视频
class FollowFeedFullscreenPage extends StatefulWidget {
  const FollowFeedFullscreenPage({super.key, required this.controller});

  final FollowFeedController controller;

  static Future<void> open(FollowFeedController controller) async {
    controller.inFullscreen = true;
    try {
      await Get.to(() => FollowFeedFullscreenPage(controller: controller));
    } finally {
      controller.inFullscreen = false;
    }
  }

  @override
  State<FollowFeedFullscreenPage> createState() =>
      _FollowFeedFullscreenPageState();
}

class _FollowFeedFullscreenPageState extends State<FollowFeedFullscreenPage> {
  FollowFeedController get _controller => widget.controller;
  late final _pageController = PageController(
    initialPage: _controller.currentIndex.value,
  );

  /// 单击切换叠加信息；播放中 3 秒无操作自动隐藏
  bool _showOverlay = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    landscapeLeftMode();
    hideSystemBar();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _pageController.dispose();
    if (Pref.horizontalScreen) {
      fullMode();
    } else {
      portraitUpMode();
    }
    showSystemBar();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _controller.isPlaying.value) {
        setState(() => _showOverlay = false);
      }
    });
  }

  void _toggleOverlay() {
    setState(() => _showOverlay = !_showOverlay);
    if (_showOverlay) _scheduleHide();
  }

  void _onPageChanged(int index) {
    _controller.onPageChanged(index);
    if (_showOverlay) _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Obx(
              () => PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                itemCount: _controller.items.length,
                onPageChanged: _onPageChanged,
                itemBuilder: _buildPage,
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_showOverlay,
              child: AnimatedOpacity(
                opacity: _showOverlay ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: _buildOverlay(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPage(BuildContext context, int index) {
    final item = _controller.items[index];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleOverlay,
      onDoubleTap: _controller.togglePlay,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (item.archive.cover case final cover?)
            LayoutBuilder(
              builder: (context, constraints) => Center(
                child: NetworkImgLayer(
                  src: cover,
                  width: constraints.maxHeight * 16 / 9,
                  height: constraints.maxHeight,
                  borderRadius: BorderRadius.zero,
                ),
              ),
            ),
          Obx(() {
            final videoController = _controller.videoController;
            if (!_controller.playerReady.value ||
                videoController == null ||
                _controller.currentIndex.value != index) {
              return const SizedBox.shrink();
            }
            return FittedBox(
              fit: BoxFit.contain,
              child: SimpleVideo(controller: videoController),
            );
          }),
          Obx(() {
            if (_controller.currentIndex.value != index) {
              return const SizedBox.shrink();
            }
            if (_controller.playError.value case final err?) {
              return Center(
                child: Text(
                  err,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              );
            }
            return const SizedBox.shrink();
          }),
        ],
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    const textStyle = TextStyle(
      color: Colors.white,
      shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
    );
    return Stack(
      children: [
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 120,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 8,
          left: padding.left + 8,
          child: TextButton.icon(
            onPressed: Get.back,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.black38,
            ),
            icon: const Icon(Icons.fullscreen_exit),
            label: const Text('退出全屏'),
          ),
        ),
        Positioned(
          left: padding.left + 16,
          right: padding.right + 16,
          bottom: 8,
          child: Obx(() {
            final index = _controller.currentIndex.value;
            if (index >= _controller.items.length) {
              return const SizedBox.shrink();
            }
            final item = _controller.items[index];
            final pos = _controller.position.value;
            final total = _controller.duration.value;
            final max = total.inMilliseconds.toDouble();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '@${item.author?.name ?? ''}  ${item.archive.title ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle.copyWith(fontSize: 14),
                ),
                Row(
                  children: [
                    IconButton(
                      onPressed: () {
                        _controller.togglePlay();
                        _scheduleHide();
                      },
                      color: Colors.white,
                      icon: Icon(
                        _controller.isPlaying.value
                            ? Icons.pause
                            : Icons.play_arrow,
                      ),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: const SliderThemeData(
                          trackHeight: 2,
                          thumbShape: RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: max <= 0
                              ? 0
                              : pos.inMilliseconds.clamp(0, max).toDouble(),
                          max: max <= 0 ? 1 : max,
                          onChanged: max <= 0
                              ? null
                              : (v) {
                                  _controller.seek(
                                    Duration(milliseconds: v.round()),
                                  );
                                  _scheduleHide();
                                },
                        ),
                      ),
                    ),
                    Text(
                      '${DurationUtils.formatDuration(pos.inSeconds)}'
                      ' / ${DurationUtils.formatDuration(total.inSeconds)}',
                      style: textStyle.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ],
            );
          }),
        ),
      ],
    );
  }
}
