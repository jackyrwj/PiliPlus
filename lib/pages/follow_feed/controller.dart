import 'dart:async';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/dynamics.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 关注流中可直接播放的一条投稿
class FollowFeedItem {
  FollowFeedItem({
    required this.dyn,
    required this.archive,
  });

  final DynamicItemModel dyn;
  final DynamicArchiveModel archive;

  ModuleAuthorModel? get author => dyn.modules.moduleAuthor;
  String get bvid => archive.bvid!;

  int? cid;
  bool? isVertical;

  /// 解析好的播放地址，翻到该页前预取
  ({String video, String? audio})? source;
  Future<String?>? _resolving;
}

class FollowFeedController extends GetxController {
  /// 只取 1080P 及以下，竖向刷视频不需要更高清晰度，也省流量
  static const int _maxQn = 80;

  /// AVC 兼容性最好
  static const int _avcCodecId = 7;

  final RxList<FollowFeedItem> items = <FollowFeedItem>[].obs;
  final Rx<LoadingState<void>> state = LoadingState<void>.loading().obs;
  final RxInt currentIndex = 0.obs;
  final RxnString playError = RxnString();

  String? _offset;
  bool _hasMore = true;
  bool _isLoadingMore = false;

  Player? player;
  VideoController? videoController;
  final RxBool playerReady = false.obs;
  final RxBool isPlaying = false.obs;
  final Rx<Duration> position = Duration.zero.obs;
  final Rx<Duration> duration = Duration.zero.obs;

  /// 当前视频的像素尺寸，用来判断是不是横屏视频
  final Rx<(int, int)> videoSize = (0, 0).obs;
  bool get isLandscapeVideo => videoSize.value.$1 > videoSize.value.$2;

  /// 横屏全屏页打开时，竖屏页被盖住也不暂停
  bool inFullscreen = false;
  List<StreamSubscription>? _subscriptions;

  /// 防止快速翻页时旧请求覆盖新的播放
  int _playToken = 0;

  /// 暂停播放的原因：切到别的 tab、被别的页面盖住、app 进入后台
  final Set<String> _blockers = {};

  /// 用户单击暂停后，恢复可见时不自动续播
  bool _userPaused = false;

  bool get _canAutoPlay => _blockers.isEmpty && !_userPaused;

  void setBlocked(String reason, bool blocked) {
    final changed = blocked ? _blockers.add(reason) : _blockers.remove(reason);
    if (!changed) return;
    if (_canAutoPlay) {
      player?.play();
    } else {
      player?.pause();
    }
  }

  @override
  void onInit() {
    super.onInit();
    _initPlayer();
    refreshFeed();
  }

  Future<void> _initPlayer() async {
    final player = await Player.create(
      configuration: const PlayerConfiguration(),
    );
    final videoController = await VideoController.create(player);
    if (isClosed) {
      player.dispose();
      return;
    }
    player
      ..setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl)
      ..setPlaylistMode(.single);
    _subscriptions = [
      player.stream.playing.listen((e) => isPlaying.value = e),
      player.stream.position.listen((e) => position.value = e),
      player.stream.duration.listen((e) => duration.value = e),
      player.stream.size.listen((e) => videoSize.value = e),
    ];
    this.player = player;
    this.videoController = videoController;
    playerReady.value = true;
    if (items.isNotEmpty) {
      _playAt(currentIndex.value);
    }
  }

  Future<void> refreshFeed() async {
    _offset = null;
    _hasMore = true;
    state.value = LoadingState<void>.loading();
    final res = await _fetch();
    if (res case Error(:final errMsg)) {
      state.value = Error(errMsg);
      return;
    }
    items.assignAll((res as Success<List<FollowFeedItem>>).response);
    state.value = const Success(null);
    currentIndex.value = 0;
    if (items.isEmpty) {
      await player?.stop();
    } else {
      _playAt(0);
    }
  }

  Future<void> loadMore() async {
    if (!_hasMore || _isLoadingMore) return;
    _isLoadingMore = true;
    final res = await _fetch();
    if (res case Success(:final response)) {
      items.addAll(response);
    }
    _isLoadingMore = false;
  }

  /// 关注动态里只保留普通投稿视频（番剧、课程、直播、图文都跳过）
  Future<LoadingState<List<FollowFeedItem>>> _fetch() async {
    final res = await DynamicsHttp.followDynamic(
      type: .video,
      offset: _offset,
    );
    switch (res) {
      case Success(:final response):
        _offset = response.offset;
        _hasMore = response.hasMore ?? false;
        final list = <FollowFeedItem>[];
        for (final item in response.items ?? const <DynamicItemModel>[]) {
          final archive = item.modules.moduleDynamic?.major?.archive;
          if (archive?.bvid case final bvid?
              when bvid.startsWith('BV') && item.visible != false) {
            list.add(FollowFeedItem(dyn: item, archive: archive!));
          }
        }
        return Success(list);
      case Error(:final errMsg):
        return Error(errMsg);
      case Loading():
        return const Error(null);
    }
  }

  void onPageChanged(int index) {
    currentIndex.value = index;
    _playAt(index);
    if (index >= items.length - 3) {
      loadMore();
    }
  }

  Future<void> _playAt(int index) async {
    final player = this.player;
    if (player == null || index >= items.length) return;
    final token = ++_playToken;
    playError.value = null;
    position.value = Duration.zero;
    duration.value = Duration.zero;
    videoSize.value = (0, 0);
    await player.stop();

    final item = items[index];
    final err = await _resolve(item);
    if (token != _playToken || isClosed) return;
    if (err != null) {
      playError.value = err;
      return;
    }
    final source = item.source!;
    String url = source.video;
    // 与 PlPlayerController 相同：用 edl 把 DASH 的音视频流合并成一个媒体
    if (source.audio case final audio?) {
      url =
          'edl://!no_chapters;%${url.length}%$url;'
          '!new_stream;!no_chapters;%${audio.length}%$audio';
    }
    _userPaused = false;
    await player.open(Media(url), play: _canAutoPlay);

    // 顺手预取下一条的播放地址，翻页时更快起播
    if (index + 1 < items.length) {
      _resolve(items[index + 1]);
    }
  }

  /// 获取 cid 与播放地址，失败时返回错误信息
  Future<String?> _resolve(FollowFeedItem item) {
    if (item.source != null) return Future.value();
    return item._resolving ??= _doResolve(item).whenComplete(
      () => item._resolving = null,
    );
  }

  Future<String?> _doResolve(FollowFeedItem item) async {
    if (item.cid == null) {
      final page = await SearchHttp.ab2cWithDimension(bvid: item.bvid);
      if (page == null) return '获取视频信息失败';
      item
        ..cid = page.cid
        ..isVertical = page.dimension?.isVertical;
    }
    final res = await VideoHttp.videoUrl(
      bvid: item.bvid,
      cid: item.cid!,
      qn: _maxQn,
      tryLook: false,
      videoType: VideoType.ugc,
    );
    switch (res) {
      case Success(:final response):
        final source = _pickSource(response);
        if (source == null) return '没有可播放的视频流';
        item.source = source;
        return null;
      case Error(:final errMsg):
        return errMsg ?? '获取播放地址失败';
      case Loading():
        return '获取播放地址失败';
    }
  }

  static ({String video, String? audio})? _pickSource(PlayUrlModel data) {
    final dash = data.dash;
    if (dash?.video case final videos? when videos.isNotEmpty) {
      final candidates = videos.where((e) => e.quality.code <= _maxQn);
      final pool = candidates.isEmpty ? videos : candidates;
      final avc = pool.where((e) => e.codecid == _avcCodecId);
      final video = (avc.isEmpty ? pool : avc).reduce(
        (a, b) => a.quality.code >= b.quality.code ? a : b,
      );
      final audios = dash!.audio;
      final audio = audios == null || audios.isEmpty
          ? null
          : audios.reduce((a, b) => a.id >= b.id ? a : b);
      return (
        video: VideoUtils.getCdnUrl(video.playUrls),
        audio: audio == null
            ? null
            : VideoUtils.getCdnUrl(audio.playUrls, isAudio: true),
      );
    }
    if (data.durl case final durl? when durl.isNotEmpty) {
      return (video: VideoUtils.getCdnUrl(durl.first.playUrls), audio: null);
    }
    return null;
  }

  void togglePlay() {
    _userPaused = isPlaying.value;
    player?.playOrPause();
  }

  void seek(Duration to) => player?.seek(to);

  @override
  void onClose() {
    _playToken++;
    for (final e in _subscriptions ?? const <StreamSubscription>[]) {
      e.cancel();
    }
    player?.dispose();
    super.onClose();
  }
}
