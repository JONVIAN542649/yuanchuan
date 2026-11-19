import 'package:flutter_test/flutter_test.dart';
import 'package:local_file_drop/services/update_service.dart';

void main() {
  test('解析 GitHub digest 字段', () {
    expect(
      UpdateService.parseAssetDigest('sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(UpdateService.parseAssetDigest(null), isNull);
    expect(UpdateService.parseAssetDigest('not-a-hash'), isNull);
  });

  test('解析 .sha256 文件正文', () {
    expect(
      UpdateService.parseSha256FileBody(
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  app.zip\n',
      ),
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    );
  });

  test('缺少哈希时拒绝下载', () async {
    expect(
      () => UpdateService.download(
        const ReleaseInfo(
          version: '9.9.9',
          notes: '',
          pageUrl: '',
          assetUrl: 'https://example.invalid/a.zip',
          assetName: 'a.zip',
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('SHA-256'),
        ),
      ),
    );
  });
}
