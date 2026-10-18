import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart' hide AssetEditAction;
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

class _MockAssetsApi extends Mock implements AssetsApi {}

class _MockStacksApi extends Mock implements StacksApi {}

class _MockTrashApi extends Mock implements TrashApi {}

void main() {
  late _MockAssetsApi api;
  late AssetApiRepository repo;

  setUp(() {
    api = _MockAssetsApi();
    repo = AssetApiRepository(api, _MockStacksApi(), _MockTrashApi());
  });

  void stubEdits(List<AssetEditActionItemResponseDto> edits) {
    when(
      () => api.getAssetEdits('asset-1', abortTrigger: any(named: 'abortTrigger')),
    ).thenAnswer((_) async => AssetEditsResponseDto(assetId: 'asset-1', edits: edits));
  }

  group('getTrim', () {
    test('returns the trim from the server', () async {
      stubEdits([
        AssetEditActionItemResponseDto(
          id: 'edit-1',
          action: AssetEditAction.trim,
          parameters: {'startMs': 1500, 'endMs': 9000},
        ),
      ]);

      final trim = await repo.getTrim('asset-1');

      expect(trim, isA<TrimEdit>());
      expect(trim?.parameters.startMs, 1500);
      expect(trim?.parameters.endMs, 9000);
    });

    test('returns null when the video is not trimmed', () async {
      stubEdits([]);

      expect(await repo.getTrim('asset-1'), isNull);
    });
  });
}
