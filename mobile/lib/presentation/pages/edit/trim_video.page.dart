import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';
import 'package:openapi/api.dart' show TrimParameters;

/// Shortest clip that can be kept, so the handles can't collapse onto each other
const _minTrimLengthMs = 500;

/// A trim within this distance of the video's ends is treated as no trim at all
const _fullRangeToleranceMs = 50;

@RoutePage()
class TrimVideoPage extends ConsumerStatefulWidget {
  final RemoteAsset asset;
  final TrimEdit? initialTrim;
  final Future<void> Function(List<AssetEdit> edits) applyEdits;

  const TrimVideoPage({super.key, required this.asset, this.initialTrim, required this.applyEdits});

  @override
  ConsumerState<TrimVideoPage> createState() => _TrimVideoPageState();
}

class _TrimVideoPageState extends ConsumerState<TrimVideoPage> {
  static final _log = Logger('TrimVideoPage');

  NativeVideoPlayerController? _controller;
  late RangeValues _range;
  late final RangeValues _initialRange;
  int _durationMs = 0;
  int _positionMs = 0;
  bool _isReady = false;
  bool _isPlaying = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _durationMs = widget.asset.durationMs ?? 0;
    final trim = widget.initialTrim?.parameters;
    _initialRange = trim == null
        ? RangeValues(0, _durationMs.toDouble())
        : RangeValues(trim.startMs.toDouble(), trim.endMs.toDouble());
    _range = _initialRange;
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      controller.onPlaybackReady.removeListener(_onPlaybackReady);
      controller.onPlaybackPositionChanged.removeListener(_onPositionChanged);
      controller.onPlaybackStatusChanged.removeListener(_onStatusChanged);
      controller.onPlaybackEnded.removeListener(_onPlaybackEnded);
      unawaited(controller.stop());
    }
    super.dispose();
  }

  bool get _hasChanges => _range != _initialRange;

  int get _startMs => _range.start.round();

  int get _endMs => _range.end.round();

  /// Trim times are relative to the original, so always preview the untrimmed video
  Future<VideoSource?> _createSource() async {
    final localId = widget.asset.localId;
    if (localId != null) {
      final File? file = await ref.read(storageRepositoryProvider).getFileForAsset(localId);
      if (file != null) {
        return VideoSource.init(
          path: CurrentPlatform.isAndroid ? file.uri.toString() : file.path,
          type: VideoSourceType.file,
        );
      }
    }

    final serverEndpoint = Store.get(StoreKey.serverEndpoint);
    return VideoSource.init(
      path: '$serverEndpoint/assets/${widget.asset.id}/original',
      type: VideoSourceType.network,
      headers: ApiService.getRequestHeaders(),
    );
  }

  Future<void> _initController(NativeVideoPlayerController controller) async {
    _controller = controller;
    controller.onPlaybackReady.addListener(_onPlaybackReady);
    controller.onPlaybackPositionChanged.addListener(_onPositionChanged);
    controller.onPlaybackStatusChanged.addListener(_onStatusChanged);
    controller.onPlaybackEnded.addListener(_onPlaybackEnded);

    try {
      final source = await _createSource();
      if (source == null || !mounted) {
        return;
      }
      await controller.loadVideoSource(source);
      await controller.setVolume(1);
    } catch (error) {
      _log.severe('Error loading video for trimming ${widget.asset.name}: $error');
    }
  }

  void _onPlaybackReady() {
    final duration = _controller?.videoInfo?.duration;
    if (!mounted || _isReady || duration == null) {
      return;
    }

    setState(() {
      _isReady = true;
      // the server validates against its own duration, so never let the end go past it
      _durationMs = min(duration, widget.asset.durationMs ?? duration);
      if (widget.initialTrim == null || _range.end > _durationMs) {
        _range = RangeValues(min(_range.start, _durationMs.toDouble()), _durationMs.toDouble());
      }
    });
    unawaited(_seekTo(_startMs));
  }

  void _onPositionChanged() {
    final position = _controller?.playbackInfo?.position;
    if (!mounted || position == null) {
      return;
    }

    setState(() => _positionMs = position);

    // loop within the selected range so it previews what will be kept
    if (_isPlaying && position >= _endMs) {
      unawaited(_seekTo(_startMs));
    }
  }

  void _onStatusChanged() {
    final status = _controller?.playbackInfo?.status;
    if (!mounted || status == null) {
      return;
    }
    setState(() => _isPlaying = status == PlaybackStatus.playing);
  }

  void _onPlaybackEnded() {
    if (!mounted) {
      return;
    }
    setState(() => _isPlaying = false);
    unawaited(_seekTo(_startMs));
  }

  Future<void> _seekTo(int positionMs) async {
    setState(() => _positionMs = positionMs);
    await _controller?.seekTo(positionMs);
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }

    if (_isPlaying) {
      await controller.pause();
      return;
    }

    if (_positionMs < _startMs || _positionMs >= _endMs) {
      await _seekTo(_startMs);
    }
    await controller.play();
  }

  void _onRangeChanged(RangeValues values) {
    var start = values.start;
    var end = values.end;
    final movedStart = start != _range.start;

    if (end - start < _minTrimLengthMs) {
      if (movedStart) {
        start = max(0, end - _minTrimLengthMs);
      } else {
        end = min(_durationMs.toDouble(), start + _minTrimLengthMs);
      }
    }

    setState(() => _range = RangeValues(start, end));
    unawaited(_seekTo((movedStart ? start : end).round()));
  }

  void _reset() {
    setState(() => _range = RangeValues(0, _durationMs.toDouble()));
    unawaited(_seekTo(0));
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    await _controller?.pause();

    final isFullRange = _startMs <= _fullRangeToleranceMs && _endMs >= _durationMs - _fullRangeToleranceMs;
    final edits = isFullRange ? const <AssetEdit>[] : [TrimEdit(TrimParameters(startMs: _startMs, endMs: _endMs))];

    try {
      await widget.applyEdits(edits);
      if (!mounted) {
        return;
      }

      ImmichToast.show(context: context, msg: context.t.success, toastType: ToastType.success);
      Navigator.of(context).pop();
    } catch (error) {
      _log.severe('Error trimming video ${widget.asset.name}: $error');
      if (!mounted) {
        return;
      }

      ImmichToast.show(context: context, msg: context.t.error_title, toastType: ToastType.error);
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<bool?> _showDiscardChangesDialog() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.t.editor_discard_edits_title),
        content: Text(context.t.editor_discard_edits_prompt),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: ButtonStyle(
              foregroundColor: WidgetStateProperty.all(context.themeData.colorScheme.onSurfaceVariant),
            ),
            child: Text(context.t.cancel),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(context.t.confirm)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ref.watch(immichThemeProvider).dark;

    return PopScope(
      canPop: !_hasChanges || _isSaving,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        final shouldDiscard = await _showDiscardChangesDialog() ?? false;
        if (shouldDiscard && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Theme(
        data: getThemeData(colorScheme: colorScheme, locale: context.locale),
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: Text(context.t.trim),
            leading: ImmichCloseButton(onPressed: () => Navigator.of(context).maybePop()),
            actions: [
              _isSaving
                  ? const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
                    )
                  : ImmichIconButton(
                      icon: Icons.done_rounded,
                      color: ImmichColor.primary,
                      variant: ImmichVariant.ghost,
                      disabled: !_hasChanges || !_isReady,
                      onPressed: _save,
                    ),
            ],
          ),
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: NativeVideoPlayerView(onViewReady: _initController)),
                      if (!_isReady) const Center(child: CircularProgressIndicator()),
                    ],
                  ),
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_formatDuration(_startMs)),
                          Text(_formatDuration(_endMs - _startMs), style: const TextStyle(fontWeight: FontWeight.bold)),
                          Text(_formatDuration(_endMs)),
                        ],
                      ),
                      RangeSlider(
                        values: _range,
                        max: max(_durationMs.toDouble(), max(_range.end, 1)),
                        onChangeStart: (_) => unawaited(_controller?.pause()),
                        onChanged: _isReady && !_isSaving ? _onRangeChanged : null,
                      ),
                      _PlaybackProgress(positionMs: _positionMs, durationMs: _durationMs),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          ImmichTextButton(
                            labelText: context.t.reset,
                            onPressed: _reset,
                            variant: ImmichVariant.ghost,
                            expanded: false,
                            disabled: !_isReady || _isSaving || (_startMs == 0 && _endMs == _durationMs),
                          ),
                          ImmichIconButton(
                            icon: _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            variant: ImmichVariant.ghost,
                            disabled: !_isReady,
                            onPressed: _togglePlayback,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin bar under the slider showing where playback is within the whole video
class _PlaybackProgress extends StatelessWidget {
  final int positionMs;
  final int durationMs;

  const _PlaybackProgress({required this.positionMs, required this.durationMs});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: LinearProgressIndicator(
        value: durationMs > 0 ? (positionMs / durationMs).clamp(0, 1) : 0,
        minHeight: 2,
        backgroundColor: Colors.transparent,
      ),
    );
  }
}

String _formatDuration(int ms) {
  final duration = Duration(milliseconds: ms);
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  final tenths = (duration.inMilliseconds % 1000) ~/ 100;
  return '$minutes:${seconds.toString().padLeft(2, '0')}.$tenths';
}
