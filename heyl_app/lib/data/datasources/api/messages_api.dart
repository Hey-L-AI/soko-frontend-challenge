import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/environment.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/services/storage_service.dart';
import '../../models/models.dart';
import '../interfaces/api_interfaces.dart';
import 'api_client.dart';

/// Real implementation of Messages API
class MessagesApi implements IMessagesApi {
  final ApiClient _apiClient;
  final StorageService? _storageService;

  MessagesApi({
    required ApiClient apiClient,
    StorageService? storageService,
  })  : _apiClient = apiClient,
        _storageService = storageService;

  Dio get _dio => _apiClient.dio;

  @override
  Future<List<MessageStarter>> getMessageStarters({String? context}) async {
    final queryParams = <String, dynamic>{};
    if (context != null) {
      queryParams['context'] = context;
    }

    print('[MessageStarters] Fetching from: ${ApiConstants.messageStarters}');
    final response = await _dio.get(
      ApiConstants.messageStarters,
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );

    print('[MessageStarters] Response status: ${response.statusCode}');
    print('[MessageStarters] Response data: ${response.data}');

    final data = response.data;
    List<dynamic> items;

    if (data is Map<String, dynamic>) {
      items = (data['items'] as List<dynamic>?) ?? [];
    } else if (data is List) {
      items = data;
    } else {
      items = [];
    }

    print('[MessageStarters] Parsed ${items.length} starters');
    if (items.isNotEmpty) {
      print('[MessageStarters] First starter: ${items.first}');
    }

    return items
        .map((e) => MessageStarter.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<MessageAcceptedResponse> sendTextMessage(
    String sessionId,
    String text, {
    LocationSnapshot? location,
    String? locale,
    String? visitorId,
  }) async {
    final response = await _dio.post(
      ApiConstants.messages(sessionId),
      data: TextMessageSendRequest(text: text, location: location, locale: locale, visitorId: visitorId).toJson(),
    );

    return MessageAcceptedResponse.fromJson(
        response.data as Map<String, dynamic>);
  }

  @override
  Future<MessageAcceptedResponse> sendImageMessage(
    String sessionId, {
    required String imagePath,
    String? caption,
    LocationSnapshot? location,
    String? locale,
  }) async {
    debugPrint('[MessagesApi] Sending image message to session: $sessionId');
    debugPrint('[MessagesApi] Image path: $imagePath');

    MultipartFile imageFile;

    if (kIsWeb && imagePath.startsWith('blob:')) {
      // On web, fetch the blob data and create MultipartFile from bytes
      debugPrint('[MessagesApi] Fetching blob data from URL...');
      final bytes = await _fetchBlobData(imagePath);
      debugPrint('[MessagesApi] Blob data fetched: ${bytes.length} bytes');

      // Determine content type from the blob data (check magic bytes)
      String mimeType = 'image/jpeg'; // Default
      String extension = 'jpg';
      if (bytes.length >= 8) {
        // Check PNG signature
        if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
          mimeType = 'image/png';
          extension = 'png';
        }
        // Check WebP signature
        else if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
                 bytes.length >= 12 && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
          mimeType = 'image/webp';
          extension = 'webp';
        }
        // Check GIF signature
        else if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
          mimeType = 'image/gif';
          extension = 'gif';
        }
      }
      debugPrint('[MessagesApi] Detected mime type: $mimeType');

      imageFile = MultipartFile.fromBytes(
        bytes,
        filename: 'image.$extension',
        contentType: DioMediaType.parse(mimeType),
      );
    } else {
      // On mobile platforms, use the file path directly
      debugPrint('[MessagesApi] Using file path directly');
      imageFile = await MultipartFile.fromFile(imagePath);
    }

    final formData = FormData.fromMap({
      'image': imageFile,
      if (caption != null) 'caption': caption,
      if (location != null) 'location': jsonEncode(location.toJson()),
      if (locale != null) 'locale': locale,
    });

    debugPrint('[MessagesApi] Sending request to: ${ApiConstants.imageMessage(sessionId)}');
    final response = await _dio.post(
      ApiConstants.imageMessage(sessionId),
      data: formData,
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: ApiConstants.uploadTimeout,
        receiveTimeout: ApiConstants.uploadTimeout,
      ),
    );

    debugPrint('[MessagesApi] Image message sent, status: ${response.statusCode}');
    return MessageAcceptedResponse.fromJson(
        response.data as Map<String, dynamic>);
  }

  @override
  Future<MessageAcceptedResponse> sendVoiceMessage(
    String sessionId, {
    required String audioPath,
    String? transcriptHint,
    LocationSnapshot? location,
    String? locale,
  }) async {
    debugPrint('[MessagesApi] Sending voice message to session: $sessionId');
    debugPrint('[MessagesApi] Audio path: $audioPath');

    MultipartFile audioFile;

    if (kIsWeb && audioPath.startsWith('blob:')) {
      // On web, fetch the blob data and create MultipartFile from bytes
      debugPrint('[MessagesApi] Fetching blob data from URL...');
      final bytes = await _fetchBlobData(audioPath);
      debugPrint('[MessagesApi] Blob data fetched: ${bytes.length} bytes');
      audioFile = MultipartFile.fromBytes(
        bytes,
        filename: 'voice_message.webm',
        contentType: DioMediaType('audio', 'webm'),
      );
    } else {
      // On mobile platforms, use the file path directly
      debugPrint('[MessagesApi] Using file path directly');
      audioFile = await MultipartFile.fromFile(audioPath);
    }

    final formData = FormData.fromMap({
      'audio': audioFile,
      if (transcriptHint != null) 'transcript_hint': transcriptHint,
      if (location != null) 'location': jsonEncode(location.toJson()),
      if (locale != null) 'locale': locale,
    });

    debugPrint('[MessagesApi] Sending request to: ${ApiConstants.voiceMessage(sessionId)}');
    final response = await _dio.post(
      ApiConstants.voiceMessage(sessionId),
      data: formData,
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: ApiConstants.uploadTimeout,
        receiveTimeout: ApiConstants.uploadTimeout,
      ),
    );

    debugPrint('[MessagesApi] Voice message sent, status: ${response.statusCode}');
    return MessageAcceptedResponse.fromJson(
        response.data as Map<String, dynamic>);
  }

  /// Fetch blob data from a blob URL (web only)
  Future<Uint8List> _fetchBlobData(String blobUrl) async {
    final response = await http.get(Uri.parse(blobUrl));
    if (response.statusCode == 200) {
      return response.bodyBytes;
    }
    throw Exception('Failed to fetch blob data: ${response.statusCode}');
  }

  @override
  Stream<MessageStreamEvent> streamMessageResponse(
    String sessionId,
    String messageId,
  ) async* {
    final endpoint = ApiConstants.messageStream(sessionId, messageId);
    final url = '${EnvironmentConfig.baseUrl}$endpoint';

    print('[SSE] Connecting to: $url');

    // Get auth token for SSE request
    String? authToken;
    if (_storageService != null) {
      authToken = await _storageService.getAccessToken();
    }
    print('[SSE] Auth token present: ${authToken != null}');

    final client = http.Client();

    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['Accept'] = 'text/event-stream';
      request.headers['Cache-Control'] = 'no-cache';
      if (EnvironmentConfig.isDev) {
        request.headers['ngrok-skip-browser-warning'] = 'true';
      }
      if (authToken != null) {
        request.headers['Authorization'] = 'Bearer $authToken';
      }

      print('[SSE] Sending request...');
      final response = await client.send(request).timeout(
            ApiConstants.streamTimeout,
            onTimeout: () => throw TimeoutException('Stream timeout'),
          );

      print('[SSE] Response status: ${response.statusCode}');
      print('[SSE] Response headers: ${response.headers}');

      if (response.statusCode != 200) {
        print('[SSE] Error: HTTP ${response.statusCode}');
        yield MessageStreamEvent(
          type: MessageStreamEventType.error,
          errorMessage: 'HTTP error: ${response.statusCode}',
        );
        return;
      }

      // Parse SSE stream
      String buffer = '';
      print('[SSE] Starting to read stream...');
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        print('[SSE] Received chunk (${chunk.length} chars)');
        print('[SSE] Chunk ends with: ${chunk.codeUnits.reversed.take(4).toList().reversed.toList()}');
        buffer += chunk;

        // Normalize line endings (handle \r\n and \r)
        buffer = buffer.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

        print('[SSE] Buffer length: ${buffer.length}, contains \\n\\n: ${buffer.contains('\n\n')}');

        // Process complete events (events end with double newline)
        // Also try with single newline followed by empty line for robustness
        while (buffer.contains('\n\n')) {
          final eventEnd = buffer.indexOf('\n\n');
          final eventData = buffer.substring(0, eventEnd);
          buffer = buffer.substring(eventEnd + 2);

          // Skip empty events and comments (lines starting with :)
          if (eventData.trim().isEmpty || eventData.trim().startsWith(':')) {
            continue;
          }

          print('[SSE] Parsing event: ${eventData.length} chars');
          final event = _parseSSEEvent(eventData);
          if (event != null) {
            print('[SSE] Yielding event: type=${event.type}, text_len=${event.text?.length ?? 0}');
            yield event;
            if (event.isDone || event.isError) {
              print('[SSE] Stream complete (done or error)');
              return;
            }
          }
        }
      }

      // Process any remaining data in buffer
      if (buffer.trim().isNotEmpty && !buffer.trim().startsWith(':')) {
        print('[SSE] Processing remaining buffer: ${buffer.length} chars');
        final event = _parseSSEEvent(buffer);
        if (event != null) {
          print('[SSE] Yielding final event: type=${event.type}');
          yield event;
        }
      }
      print('[SSE] Stream ended normally');
    } on TimeoutException {
      print('[SSE] Timeout error');
      yield const MessageStreamEvent(
        type: MessageStreamEventType.error,
        errorMessage: 'Stream timeout waiting for response',
      );
    } catch (e) {
      print('[SSE] Exception: $e');
      yield MessageStreamEvent(
        type: MessageStreamEventType.error,
        errorMessage: e.toString(),
      );
    } finally {
      print('[SSE] Closing client');
      client.close();
    }
  }

  /// Parse SSE event from raw data
  MessageStreamEvent? _parseSSEEvent(String eventData) {
    String? eventType;
    String? data;

    for (final line in eventData.split('\n')) {
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        data = line.substring(5).trim();
      }
    }

    if (eventType == null || data == null) {
      return null;
    }

    try {
      final jsonData = json.decode(data) as Map<String, dynamic>;
      return MessageStreamEvent.fromJson(eventType, jsonData);
    } catch (e) {
      return MessageStreamEvent(
        type: MessageStreamEventType.error,
        errorMessage: 'Failed to parse event: $e',
      );
    }
  }
}
