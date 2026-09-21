import '../../models/library_feed.dart';
import '../interfaces/api_interfaces.dart';

class MockLibraryApi implements ILibraryApi {
  @override
  Future<LibraryFeedOut> getLibrary({
    int limit = 20,
    String? cursor,
    String? types,
    String sort = 'recent',
    String? q,
    String? membership,
    String? when,
    String? fromDate,
    String? toDate,
    String? direction,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return const LibraryFeedOut(items: [], nextCursor: null);
  }

  @override
  Future<LibraryPinOut> pinLibraryItem({
    required LibraryFeedItemType type,
    required String id,
  }) async {
    return LibraryPinOut(
      type: type,
      id: id,
      pinState: LibraryPinState.userPinned,
    );
  }

  @override
  Future<LibraryPinOut> unpinLibraryItem({
    required LibraryFeedItemType type,
    required String id,
  }) async {
    return LibraryPinOut(
      type: type,
      id: id,
      pinState: LibraryPinState.notPinned,
    );
  }
}
