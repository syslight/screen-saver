import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:smart_frame/core/config/app_config.dart';
import 'package:smart_frame/features/music/data/remote_music_source.dart';
import 'package:smart_frame/features/music/domain/music_models.dart';
import 'package:smart_frame/features/photos/application/photo_index_service.dart';
import 'package:smart_frame/features/voice/application/voice_provider.dart';

typedef MusicRemoteCommand = void Function(String action, double? value);

/// 相册背景音乐：display 从服务端选曲并缓存，不在设备上生成音频。
class MusicService extends ChangeNotifier {
  MusicService({
    required this.configService,
    required this.photoIndex,
    this.remoteSource,
    this.minStoryDuration = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ConfigService configService;
  final PhotoIndexService photoIndex;
  final RemoteMusicSource? remoteSource;
  final Duration minStoryDuration;
  final DateTime Function() _now;

  MusicRemoteCommand? remoteCommand;

  final Map<MusicMood, List<MusicTrack>> _library = {};
  AudioPlayer? _activePlayer;
  AudioPlayer? _standbyPlayer;
  MusicTrack? _track;
  VoiceProvider? _voice;
  Timer? _quietTimer;
  Timer? _duckReleaseTimer;
  DateTime? _trackStartedAt;
  int _transitionSequence = 0;
  int _variant = 0;
  bool _ducked = false;

  MusicMood currentMood = MusicMood.warm;
  String currentTitle = '准备智能配乐…';

  AppConfig get _config => configService.config;
  bool get enabled => _config.musicEnabled;
  bool get muted => _config.musicMuted;
  double get volume => _config.musicVolume.clamp(0.0, 1.0);
  bool get outputEnabled => _config.musicOutputEnabled;
  bool get quietHoursActive => isMusicQuietHour(
    _now(),
    startHour: _config.musicQuietStartHour,
    endHour: _config.musicQuietEndHour,
  );
  bool get isPlaying => enabled && (_track != null || !outputEnabled);

  double get effectiveVolume {
    if (!enabled || muted || quietHoursActive) return 0;
    return volume * (_ducked ? 0.15 : 1.0);
  }

  Future<void> init() async {
    if (remoteSource == null) {
      await Directory(_config.musicDir).create(recursive: true);
      await reloadLibrary();
    }
    photoIndex.addListener(_onPhotoDescriptionChanged);
    _quietTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_applyVolume()),
    );
    await _selectForCurrentPhoto(force: true);
  }

  void bindVoice(VoiceProvider voice) {
    _voice?.removeListener(_onVoiceChanged);
    _voice = voice;
    voice.addListener(_onVoiceChanged);
    _onVoiceChanged();
  }

  Future<void> reloadLibrary() async {
    _library.clear();
    final dir = Directory(_config.musicDir);
    if (!await dir.exists()) return;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File ||
          !_musicExtensions.contains(p.extension(entity.path).toLowerCase())) {
        continue;
      }
      final mood = _moodFromPath(entity.path);
      (_library[mood] ??= []).add(
        MusicTrack(
          file: entity,
          title: p.basenameWithoutExtension(entity.path),
          mood: mood,
        ),
      );
    }
    for (final tracks in _library.values) {
      tracks.sort((a, b) => a.file.path.compareTo(b.file.path));
    }
  }

  Future<void> refreshForCurrentPhoto() => _selectForCurrentPhoto(force: true);

  Future<void> setEnabled(
    bool value, {
    bool persist = true,
    bool forward = true,
  }) async {
    _config.musicEnabled = value;
    if (persist) unawaited(configService.save());
    if (forward) remoteCommand?.call('set_music_enabled', value ? 1 : 0);
    if (value) {
      if (_track == null) {
        await _selectForCurrentPhoto(force: true);
      } else {
        await _activePlayer?.resume();
      }
    } else {
      await _activePlayer?.pause();
      await _standbyPlayer?.pause();
    }
    await _applyVolume();
    notifyListeners();
  }

  Future<void> setMuted(
    bool value, {
    bool persist = true,
    bool forward = true,
  }) async {
    _config.musicMuted = value;
    if (persist) unawaited(configService.save());
    if (forward) remoteCommand?.call('set_music_muted', value ? 1 : 0);
    await _applyVolume();
    notifyListeners();
  }

  Future<void> setVolume(
    double value, {
    bool persist = true,
    bool forward = true,
  }) async {
    _config.musicVolume = value.clamp(0.0, 1.0);
    if (persist) unawaited(configService.save());
    if (forward) remoteCommand?.call('set_music_volume', _config.musicVolume);
    await _applyVolume();
    notifyListeners();
  }

  Future<void> setOutputEnabled(bool value) async {
    _config.musicOutputEnabled = value;
    if (!value) {
      await _activePlayer?.stop();
      await _standbyPlayer?.stop();
      _track = null;
    } else {
      await _selectForCurrentPhoto(force: true);
    }
    notifyListeners();
  }

  Future<void> applyRemoteState(Map<String, dynamic> state) async {
    var changed = false;
    final remoteEnabled = state['musicEnabled'];
    final remoteMuted = state['musicMuted'];
    final remoteVolume = state['musicVolume'];
    if (remoteEnabled is bool && remoteEnabled != enabled) {
      _config.musicEnabled = remoteEnabled;
      changed = true;
    }
    if (remoteMuted is bool && remoteMuted != muted) {
      _config.musicMuted = remoteMuted;
      changed = true;
    }
    if (remoteVolume is num && remoteVolume.toDouble() != volume) {
      _config.musicVolume = remoteVolume.toDouble().clamp(0.0, 1.0);
      changed = true;
    }
    if (!changed) return;
    unawaited(configService.save());
    if (enabled && _track == null) {
      await _selectForCurrentPhoto(force: true);
    } else if (!enabled) {
      await _activePlayer?.pause();
      await _standbyPlayer?.pause();
    } else {
      await _activePlayer?.resume();
    }
    await _applyVolume();
    notifyListeners();
  }

  void _onPhotoDescriptionChanged() => unawaited(_selectForCurrentPhoto());

  Future<void> _selectForCurrentPhoto({bool force = false}) async {
    final mood = selectMusicMood(photoIndex.currentDescription, now: _now());
    final started = _trackStartedAt;
    if (!force &&
        started != null &&
        _now().difference(started) < minStoryDuration) {
      return;
    }
    _variant = !force && mood == currentMood ? (_variant + 1) % 3 : 0;
    currentMood = mood;
    if (!outputEnabled) {
      currentTitle = '${mood.label} · 自动配乐';
      _trackStartedAt = _now();
      notifyListeners();
      return;
    }
    final track = await _trackFor(mood, _variant);
    if (track == null) {
      await _activePlayer?.stop();
      await _standbyPlayer?.stop();
      _track = null;
      currentTitle = '${mood.label} · 服务端暂无曲目';
      _trackStartedAt = _now();
      notifyListeners();
      return;
    }
    await _switchTo(track);
  }

  Future<MusicTrack?> _trackFor(MusicMood mood, int variant) async {
    final remote = remoteSource;
    if (remote != null) {
      return remote.select(photoIndex.currentDescription, mood);
    }
    final custom = _library[mood];
    if (custom != null && custom.isNotEmpty) {
      final index = variant % custom.length;
      return custom[index];
    }
    return null;
  }

  Future<void> _switchTo(MusicTrack next) async {
    if (_track?.file.path == next.file.path) return;
    final sequence = ++_transitionSequence;
    final nextPlayer = _standbyPlayer ??= AudioPlayer();
    await nextPlayer.setReleaseMode(ReleaseMode.loop);
    await nextPlayer.setVolume(0);
    await nextPlayer.play(DeviceFileSource(next.file.path));

    final oldPlayer = _activePlayer;
    _track = next;
    currentMood = next.mood;
    currentTitle = next.title;
    _trackStartedAt = _now();
    notifyListeners();

    const steps = 30;
    for (var step = 1; step <= steps; step++) {
      if (sequence != _transitionSequence) return;
      final ratio = step / steps;
      final target = effectiveVolume;
      await nextPlayer.setVolume(target * ratio);
      await oldPlayer?.setVolume(target * (1 - ratio));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (sequence != _transitionSequence) return;
    await oldPlayer?.stop();
    _standbyPlayer = oldPlayer;
    _activePlayer = nextPlayer;
    if (!enabled) await _activePlayer?.pause();
    await _applyVolume();
  }

  void _onVoiceChanged() {
    final state = _voice?.stateText ?? '';
    final speaking =
        state.contains('聆听') ||
        state.contains('识别') ||
        state.contains('播报') ||
        state.contains('继续说');
    _duckReleaseTimer?.cancel();
    if (speaking) {
      _ducked = true;
      unawaited(_applyVolume());
      notifyListeners();
      return;
    }
    _duckReleaseTimer = Timer(const Duration(seconds: 2), () {
      _ducked = false;
      unawaited(_applyVolume());
      notifyListeners();
    });
  }

  Future<void> _applyVolume() async {
    final target = effectiveVolume;
    await _activePlayer?.setVolume(target);
    await _standbyPlayer?.setVolume(target);
  }

  @override
  void dispose() {
    _transitionSequence++;
    _quietTimer?.cancel();
    _duckReleaseTimer?.cancel();
    photoIndex.removeListener(_onPhotoDescriptionChanged);
    _voice?.removeListener(_onVoiceChanged);
    unawaited(_activePlayer?.dispose());
    unawaited(_standbyPlayer?.dispose());
    super.dispose();
  }
}

bool isMusicQuietHour(
  DateTime now, {
  required int startHour,
  required int endHour,
}) {
  final start = startHour.clamp(0, 23);
  final end = endHour.clamp(0, 23);
  if (start == end) return false;
  return start < end
      ? now.hour >= start && now.hour < end
      : now.hour >= start || now.hour < end;
}

const _musicExtensions = {'.mp3', '.wav', '.ogg', '.m4a', '.aac', '.flac'};

MusicMood _moodFromPath(String path) {
  final lower = path.toLowerCase();
  const keywords = <MusicMood, List<String>>{
    MusicMood.childhood: ['童年', '成长', 'child'],
    MusicMood.journey: ['旅行', '远方', 'journey', 'travel'],
    MusicMood.memory: ['回忆', '岁月', 'memory'],
    MusicMood.celebration: ['欢聚', '庆祝', 'celebration', 'party'],
    MusicMood.calm: ['宁静', '风景', 'calm', 'nature'],
    MusicMood.warm: ['温暖', '日常', 'warm'],
  };
  for (final entry in keywords.entries) {
    if (entry.value.any(lower.contains)) return entry.key;
  }
  return MusicMood.warm;
}
