import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/main_layout.dart';
import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/pages/follow_feed/controller.dart';
import 'package:PiliPlus/pages/follow_feed/fullscreen.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 关注 UP 主投稿的竖向翻页流（底部导航的「关注」tab）
class FollowFeedPage extends StatefulWidget {
  const FollowFeedPage({super.key});

  @override
  State<FollowFeedPage> createState() => _FollowFeedPageState();
}

class _FollowFeedPageState extends State<FollowFeedPage>
    with
        AutomaticKeepAliveClientMixin,
        RouteAware,
        RouteAwareMixin,
        WidgetsBindingObserver {
  final _controller = Get.put(FollowFeedController());
  final _pageController = PageController();
  final _mainController = Get.find<MainController>();
  Worker? _tabWorker;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabWorker = ever(_mainController.selectedIndex, _onTabChanged);
    _onTabChanged(_mainController.selectedIndex.value);
  }

  void _onTabChanged(int index) {
    final bars = _mainController.navigationBars;
    final visible = index < bars.length && bars[index] == .followFeed;
    _controller.setBlocked('tab', !visible);
  }

  // 视频详情、UP 主页等页面盖在上面时暂停（自己的横屏全屏页除外）
  @override
  void didPushNext() {
    if (!_controller.inFullscreen) _controller.setBlocked('route', true);
  }

  @override
  void didPopNext() => _controller.setBlocked('route', false);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.setBlocked('background', state != .resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabWorker?.dispose();
    _pageController.dispose();
    Get.delete<FollowFeedController>();
    super.dispose();
  }

  Future<void> _enterFullscreen() async {
    await FollowFeedFullscreenPage.open(_controller);
    // 全屏里可能翻过页，回到竖屏时停在同一条
    if (mounted && _pageController.hasClients) {
      _pageController.jumpToPage(_controller.currentIndex.value);
    }
  }

  Future<void> _onRefresh() async {
    if (_pageController.hasClients) _pageController.jumpToPage(0);
    await _controller.refreshFeed();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 底部导航栏盖在页面上，视频区域只到导航栏上沿为止
    return ValueListenableBuilder<double>(
      valueListenable: MainLayout.bottomNavHeight,
      // 结构保持不变（导航栏高度为 0 时也一样），避免横竖屏切换时重建翻页状态
      builder: (context, navHeight, _) => ColoredBox(
        color: Colors.black,
        child: Padding(
          padding: EdgeInsets.only(bottom: navHeight),
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: navHeight > 0,
            child: Builder(builder: _buildPage),
          ),
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: Obx(() => _buildBody(_controller.state.value)),
          ),
          Positioned(
            top: padding.top,
            left: 52,
            right: 4,
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '关注',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      shadows: _textShadow,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _onRefresh,
                  icon: const Icon(Icons.refresh, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(LoadingState<void> state) {
    return switch (state) {
      Loading() => const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
      Error(:final errMsg) => _ErrorView(
        message: errMsg,
        onRetry: _controller.refreshFeed,
      ),
      Success() =>
        _controller.items.isEmpty
            ? _ErrorView(
                message: '关注的 UP 主暂时没有新投稿',
                onRetry: _controller.refreshFeed,
              )
            : PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                itemCount: _controller.items.length,
                onPageChanged: _controller.onPageChanged,
                itemBuilder: (context, index) => _FeedPage(
                  controller: _controller,
                  index: index,
                  onFullscreen: _enterFullscreen,
                ),
              ),
    };
  }
}

const _textShadow = [Shadow(blurRadius: 6, color: Colors.black54)];

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.dark(),
      child: CustomScrollView(
        slivers: [
          HttpError(errMsg: message, onReload: onRetry),
        ],
      ),
    );
  }
}

class _FeedPage extends StatelessWidget {
  const _FeedPage({
    required this.controller,
    required this.index,
    required this.onFullscreen,
  });

  final FollowFeedController controller;
  final int index;
  final VoidCallback onFullscreen;

  FollowFeedItem get item => controller.items[index];

  Future<void> _openDetail() async {
    final item = this.item;
    final cid = item.cid ?? await SearchHttp.ab2c(bvid: item.bvid);
    if (cid == null) return;
    await PageUtils.toVideoPage(
      bvid: item.bvid,
      cid: cid,
      cover: item.archive.cover,
      title: item.archive.title,
      isVertical: item.isVertical ?? false,
    );
  }

  Future<void> _openAuthor() async {
    final mid = item.author?.mid;
    if (mid == null) return;
    await Get.toNamed('/member?mid=$mid');
  }

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    final archive = item.archive;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: controller.togglePlay,
      onDoubleTap: _openDetail,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 封面先垫底，视频首帧出来后会盖住
          if (archive.cover case final cover?)
            LayoutBuilder(
              builder: (context, constraints) => Center(
                child: NetworkImgLayer(
                  src: cover,
                  width: constraints.maxWidth,
                  height: constraints.maxWidth * 9 / 16,
                  borderRadius: BorderRadius.zero,
                ),
              ),
            ),
          Obx(() {
            final videoController = controller.videoController;
            if (!controller.playerReady.value ||
                videoController == null ||
                controller.currentIndex.value != index) {
              return const SizedBox.shrink();
            }
            return FittedBox(
              fit: BoxFit.contain,
              child: SimpleVideo(controller: videoController),
            );
          }),
          Obx(() {
            if (controller.currentIndex.value != index) {
              return const SizedBox.shrink();
            }
            if (controller.playError.value case final err?) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    err,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              );
            }
            if (!controller.isPlaying.value &&
                controller.position.value > Duration.zero) {
              return const Center(
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 72,
                  color: Colors.white70,
                ),
              );
            }
            return const SizedBox.shrink();
          }),
          // 横屏视频画面正下方的「全屏」按钮
          LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                Obx(() {
                  if (controller.currentIndex.value != index ||
                      !controller.isLandscapeVideo) {
                    return const SizedBox.shrink();
                  }
                  final (w, h) = controller.videoSize.value;
                  final frameHeight = constraints.maxWidth * h / w;
                  return Positioned(
                    top: (constraints.maxHeight + frameHeight) / 2 + 12,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: OutlinedButton.icon(
                        onPressed: onFullscreen,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                          backgroundColor: Colors.black26,
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.fullscreen, size: 18),
                        label: const Text('全屏'),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 260,
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
            left: 16,
            right: 16,
            bottom: bottom + 28,
            child: _buildInfo(item),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottom,
            child: Obx(() => _buildProgress(controller.currentIndex.value)),
          ),
        ],
      ),
    );
  }

  Widget _buildInfo(FollowFeedItem item) {
    final author = item.author;
    final archive = item.archive;
    const style = TextStyle(color: Colors.white, shadows: _textShadow);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: _openAuthor,
          child: Row(
            children: [
              if (author?.face case final face?)
                NetworkImgLayer(
                  src: face,
                  width: 34,
                  height: 34,
                  type: .avatar,
                ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '@${author?.name ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (author?.pubTime case final pubTime?) ...[
                const SizedBox(width: 8),
                Text(
                  pubTime,
                  style: style.copyWith(fontSize: 12, color: Colors.white70),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          archive.title ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(fontSize: 15, height: 1.4),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              [
                if (archive.stat?.play case final play?)
                  '${NumUtils.numFormat(play)}播放',
                if (archive.stat?.danmu case final danmu?)
                  '${NumUtils.numFormat(danmu)}弹幕',
                ?archive.durationText,
              ].join('  ·  '),
              style: style.copyWith(fontSize: 12, color: Colors.white70),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _openDetail,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.open_in_full, size: 16),
              label: const Text('详情'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildProgress(int currentIndex) {
    if (currentIndex != index) return const SizedBox(height: 20);
    final total = controller.duration.value;
    final pos = controller.position.value;
    final max = total.inMilliseconds.toDouble();
    return SizedBox(
      height: 20,
      child: Row(
        children: [
          Expanded(
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 2,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: RoundSliderOverlayShape(overlayRadius: 10),
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
                    : (v) => controller.seek(
                        Duration(milliseconds: v.round()),
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              '${DurationUtils.formatDuration(pos.inSeconds)}'
              ' / ${DurationUtils.formatDuration(total.inSeconds)}',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
