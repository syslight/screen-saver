import 'dart:io';

import 'package:flutter/services.dart';

enum NativeWakeEventType { availability, wake }

class NativeWakeEvent {
  const NativeWakeEvent({
    required this.type,
    this.available = false,
    this.wakeWord,
    this.source,
    this.adapter,
    this.reason,
  });

  final NativeWakeEventType type;
  final bool available;
  final String? wakeWord;
  final int? source;
  final String? adapter;
  final String? reason;

  factory NativeWakeEvent.fromMap(Map<Object?, Object?> map) {
    return NativeWakeEvent(
      type: map['event'] == 'wake'
          ? NativeWakeEventType.wake
          : NativeWakeEventType.availability,
      available: map['available'] == true,
      wakeWord: map['wakeWord'] as String?,
      source: map['source'] as int?,
      adapter: map['adapter'] as String?,
      reason: map['reason'] as String?,
    );
  }
}

/// Receives only wake metadata from a device vendor adapter. No PCM, ASR text,
/// wake model, or speech model crosses this platform channel.
class NativeWakeWord {
  const NativeWakeWord();

  static const _channel = EventChannel('smart_frame/native_wake');

  Stream<NativeWakeEvent> get events {
    if (!Platform.isAndroid) return const Stream.empty();
    return _channel.receiveBroadcastStream().map((event) {
      return NativeWakeEvent.fromMap(event as Map<Object?, Object?>);
    });
  }
}
