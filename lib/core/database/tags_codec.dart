import 'dart:convert';

/// Serializes item tags into the JSON text stored in `items.tags`.
///
/// This is the only code that knows about the column's representation. A
/// future relational tag schema only needs to migrate the data behind this
/// codec.
abstract final class TagsCodec {
  static String encode(List<String> tags) => jsonEncode(tags);

  static List<String> decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('items.tags does not hold a JSON array');
    }
    return List.unmodifiable(
      decoded.map((element) {
        if (element is! String) {
          throw const FormatException('items.tags holds a non-string tag');
        }
        return element;
      }),
    );
  }
}
