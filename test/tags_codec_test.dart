import 'package:flutter_test/flutter_test.dart';
import 'package:stash/core/database/tags_codec.dart';

void main() {
  group('TagsCodec', () {
    test('round-trips an empty tag list', () {
      expect(TagsCodec.decode(TagsCodec.encode(const [])), isEmpty);
    });

    test('round-trips multiple tags preserving order', () {
      const tags = ['ssh', 'git', 'windows'];
      expect(TagsCodec.decode(TagsCodec.encode(tags)), tags);
    });

    test('round-trips unicode and punctuation tags', () {
      const tags = ['中文标签', 'réseau', 'cli:git#push!', 'a tag with spaces'];
      expect(TagsCodec.decode(TagsCodec.encode(tags)), tags);
    });

    test('rejects values that are not JSON arrays', () {
      expect(
        () => TagsCodec.decode('{"not": "an array"}'),
        throwsFormatException,
      );
    });

    test('rejects arrays holding non-string entries', () {
      expect(() => TagsCodec.decode('[1, 2]'), throwsFormatException);
    });
  });
}
