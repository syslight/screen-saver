library;

import 'dart:convert';

const int nodeProtocolVersion = 1;

final class ProtocolException implements Exception {
  const ProtocolException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ProtocolException($code, $message)';
}

final class NodeEnvelope {
  const NodeEnvelope({
    required this.protocolVersion,
    required this.messageId,
    required this.sequence,
    required this.type,
    required this.sentAt,
    required this.nodeId,
    required this.roomId,
    required this.sessionId,
    required this.payload,
  });

  final int protocolVersion;
  final String messageId;
  final int sequence;
  final String type;
  final DateTime sentAt;
  final String? nodeId;
  final String? roomId;
  final String? sessionId;
  final Map<String, Object?> payload;

  static const Set<String> supportedTypes = {
    'node.hello',
    'node.capabilities',
    'heartbeat.ping',
    'heartbeat.pong',
    'command.request',
    'command.result',
    'node.event',
    'voice.turn.start',
    'voice.turn.stop',
    'voice.turn.state',
    'audio.play',
    'audio.stream.start',
    'audio.stream.end',
    'error',
  };

  factory NodeEnvelope.fromJson(Map<String, Object?> json) {
    const fields = {
      'protocolVersion',
      'messageId',
      'sequence',
      'type',
      'sentAt',
      'nodeId',
      'roomId',
      'sessionId',
      'payload',
    };
    if (json.keys.any((key) => !fields.contains(key))) {
      throw const ProtocolException(
        'invalid_envelope',
        'Unknown envelope field',
      );
    }
    final version = json['protocolVersion'];
    if (version != nodeProtocolVersion) {
      throw ProtocolException(
        'unsupported_protocol_version',
        'Protocol version $version is not supported',
      );
    }
    final type = json['type'];
    if (type is! String || !supportedTypes.contains(type)) {
      throw ProtocolException('unknown_message_type', 'Unknown type: $type');
    }
    final payload = json['payload'];
    if (payload is! Map<String, Object?>) {
      throw const ProtocolException(
        'invalid_payload',
        'Payload must be an object',
      );
    }
    try {
      _validatePayload(type, payload);
    } on ProtocolException catch (error) {
      throw ProtocolException('invalid_payload', error.message);
    }
    try {
      return NodeEnvelope(
        protocolVersion: version as int,
        messageId: _uuidString(json, 'messageId'),
        sequence: _positiveInt(json, 'sequence'),
        type: type,
        sentAt: DateTime.parse(_string(json, 'sentAt')).toUtc(),
        nodeId: _nullableUuid(json, 'nodeId'),
        roomId: _nullableUuid(json, 'roomId'),
        sessionId: _nullableUuid(json, 'sessionId'),
        payload: payload,
      );
    } on ProtocolException {
      rethrow;
    } catch (_) {
      throw const ProtocolException(
        'invalid_envelope',
        'Envelope field is invalid',
      );
    }
  }

  factory NodeEnvelope.decode(String source) {
    final value = jsonDecode(source);
    if (value is! Map<String, Object?>) {
      throw const ProtocolException(
        'invalid_envelope',
        'Message must be an object',
      );
    }
    return NodeEnvelope.fromJson(value);
  }

  Map<String, Object?> toJson() => {
    'protocolVersion': protocolVersion,
    'messageId': messageId,
    'sequence': sequence,
    'type': type,
    'sentAt': sentAt.toUtc().toIso8601String(),
    'nodeId': nodeId,
    'roomId': roomId,
    'sessionId': sessionId,
    'payload': payload,
  };

  String encode() => jsonEncode(toJson());
}

final class NodeCapability {
  const NodeCapability({
    required this.capabilityId,
    required this.type,
    required this.status,
    required this.properties,
    required this.commands,
  });

  final String capabilityId;
  final String type;
  final String status;
  final Map<String, Object?> properties;
  final List<String> commands;

  factory NodeCapability.fromJson(Map<String, Object?> json) {
    _onlyKeys(json, {
      'capabilityId',
      'type',
      'status',
      'properties',
      'commands',
    });
    final commands = json['commands'];
    final properties = json['properties'];
    final status = json['status'];
    if (commands is! List || commands.any((item) => item is! String)) {
      throw const ProtocolException(
        'invalid_payload',
        'Capability commands are invalid',
      );
    }
    if (properties is! Map<String, Object?> ||
        status is! String ||
        !{'online', 'busy', 'disabled', 'error'}.contains(status)) {
      throw const ProtocolException('invalid_payload', 'Capability is invalid');
    }
    final type = _string(json, 'type');
    final expectedProperties = <String, Map<String, Type>>{
      'camera': {'supportsStill': bool},
      'microphone_array': {'channels': int},
      'speaker': {'volumeControl': bool},
      'display': {'touch': bool},
    };
    final propertyTypes = expectedProperties[type];
    if (propertyTypes != null) {
      for (final entry in propertyTypes.entries) {
        final value = properties[entry.key];
        if (value != null && value.runtimeType != entry.value) {
          throw ProtocolException(
            'invalid_payload',
            '$type.properties.${entry.key} has the wrong type',
          );
        }
      }
    }
    return NodeCapability(
      capabilityId: _string(json, 'capabilityId'),
      type: type,
      status: status,
      properties: properties,
      commands: commands.cast<String>(),
    );
  }
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw ProtocolException(
      'invalid_envelope',
      '$key must be a non-empty string',
    );
  }
  return value;
}

String _uuidString(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  if (!_uuidPattern.hasMatch(value)) {
    throw ProtocolException('invalid_envelope', '$key must be a UUID');
  }
  return value;
}

String? _nullableUuid(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value != null && value is! String) {
    throw ProtocolException('invalid_envelope', '$key must be a UUID or null');
  }
  if (value is String && !_uuidPattern.hasMatch(value)) {
    throw ProtocolException('invalid_envelope', '$key must be a UUID or null');
  }
  return value as String?;
}

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

int _positiveInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value < 1) {
    throw ProtocolException('invalid_envelope', '$key must be positive');
  }
  return value;
}

void _validatePayload(String type, Map<String, Object?> payload) {
  switch (type) {
    case 'node.hello':
      _onlyKeys(payload, {
        'deviceKey',
        'softwareVersion',
        'platform',
        'mediaProtocolVersion',
      });
      for (final key in ['deviceKey', 'softwareVersion', 'platform']) {
        _string(payload, key);
      }
      if (payload['mediaProtocolVersion'] is! int) {
        throw const ProtocolException(
          'invalid_payload',
          'mediaProtocolVersion is invalid',
        );
      }
    case 'node.capabilities':
      _onlyKeys(payload, {'capabilities'});
      final capabilities = payload['capabilities'];
      if (capabilities is! List) {
        throw const ProtocolException(
          'invalid_payload',
          'capabilities must be a list',
        );
      }
      for (final item in capabilities) {
        if (item is! Map<String, Object?>) {
          throw const ProtocolException(
            'invalid_payload',
            'capability must be an object',
          );
        }
        NodeCapability.fromJson(item);
      }
    case 'heartbeat.ping' || 'heartbeat.pong':
      _onlyKeys(payload, {'nonce'});
      _string(payload, 'nonce');
    case 'command.request':
      _onlyKeys(payload, {'commandName', 'arguments'});
      _string(payload, 'commandName');
      if (payload['arguments'] is! Map<String, Object?>) {
        throw const ProtocolException(
          'invalid_payload',
          'arguments must be an object',
        );
      }
    case 'command.result':
      _onlyKeys(payload, {
        'requestMessageId',
        'success',
        'result',
        'errorCode',
      });
      _string(payload, 'requestMessageId');
      if (payload['success'] is! bool ||
          payload['result'] is! Map<String, Object?>) {
        throw const ProtocolException(
          'invalid_payload',
          'command result is invalid',
        );
      }
      if (payload['errorCode'] != null && payload['errorCode'] is! String) {
        throw const ProtocolException(
          'invalid_payload',
          'errorCode must be a string or null',
        );
      }
    case 'node.event':
      _onlyKeys(payload, {'eventName', 'data'});
      _string(payload, 'eventName');
      if (payload['data'] is! Map<String, Object?>) {
        throw const ProtocolException(
          'invalid_payload',
          'event data must be an object',
        );
      }
    case 'voice.turn.start':
      _onlyKeys(payload, {'turnId', 'encoding', 'sampleRate', 'channels'});
      _string(payload, 'turnId');
      if (payload['encoding'] != 'pcm_s16le' ||
          payload['sampleRate'] != 16000 ||
          payload['channels'] != 1) {
        throw const ProtocolException(
          'invalid_payload',
          'voice input format is invalid',
        );
      }
    case 'voice.turn.stop':
      _onlyKeys(payload, {'turnId', 'cancelled'});
      _string(payload, 'turnId');
      if (payload['cancelled'] != null && payload['cancelled'] is! bool) {
        throw const ProtocolException(
          'invalid_payload',
          'voice turn cancelled flag is invalid',
        );
      }
    case 'voice.turn.state':
      _onlyKeys(payload, {
        'turnId',
        'state',
        'targetNodeId',
        'transcript',
        'reply',
        'continueDialog',
      });
      _string(payload, 'turnId');
      _string(payload, 'targetNodeId');
      if (!{
            'listening',
            'processing',
            'speaking',
            'idle',
            'error',
          }.contains(payload['state']) ||
          payload['transcript'] is! String ||
          payload['reply'] is! String ||
          (payload['continueDialog'] != null &&
              payload['continueDialog'] is! bool)) {
        throw const ProtocolException(
          'invalid_payload',
          'voice turn state is invalid',
        );
      }
    case 'audio.play':
      _onlyKeys(payload, {'turnId', 'mediaType', 'byteLength'});
      _string(payload, 'turnId');
      if (payload['mediaType'] != 'audio/wav' ||
          payload['byteLength'] is! int ||
          (payload['byteLength'] as int) < 0) {
        throw const ProtocolException(
          'invalid_payload',
          'audio playback metadata is invalid',
        );
      }
    case 'audio.stream.start':
      _onlyKeys(payload, {
        'turnId',
        'mediaType',
        'encoding',
        'sampleRate',
        'channels',
      });
      _string(payload, 'turnId');
      if (payload['mediaType'] != 'audio/pcm' ||
          payload['encoding'] != 'pcm_s16le' ||
          payload['sampleRate'] is! int ||
          (payload['sampleRate'] as int) < 8000 ||
          (payload['sampleRate'] as int) > 48000 ||
          payload['channels'] != 1) {
        throw const ProtocolException(
          'invalid_payload',
          'audio stream metadata is invalid',
        );
      }
    case 'audio.stream.end':
      _onlyKeys(payload, {'turnId', 'byteLength'});
      _string(payload, 'turnId');
      if (payload['byteLength'] is! int || (payload['byteLength'] as int) < 0) {
        throw const ProtocolException(
          'invalid_payload',
          'audio stream completion is invalid',
        );
      }
    case 'error':
      _onlyKeys(payload, {'code', 'message', 'details'});
      _string(payload, 'code');
      _string(payload, 'message');
      if (payload['details'] is! Map<String, Object?>) {
        throw const ProtocolException(
          'invalid_payload',
          'error details must be an object',
        );
      }
  }
}

void _onlyKeys(Map<String, Object?> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const ProtocolException('invalid_payload', 'Unknown payload field');
  }
}
