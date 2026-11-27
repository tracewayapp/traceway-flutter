import 'wireframe_css.dart';

/// One node of the wireframe DOM: an element or a text node.
///
/// Nodes are immutable. A capture reuses the previous frame's node when
/// nothing about it changed, so consecutive frames share their unchanged
/// subtrees: a frame costs memory only for what moved, and a diff skips
/// every subtree that is the same object in both frames.
class VNode {
  VNode.element(this.id, String this.tag, this.attributes, this.children)
      : text = null;

  VNode.text(this.id, String this.text)
      : tag = null,
        attributes = const {},
        children = const [];

  /// The rrweb node id. The same element keeps its id from frame to frame.
  final int id;

  /// Null for a text node.
  final String? tag;
  final String? text;
  final Map<String, String> attributes;
  final List<VNode> children;

  bool get isText => tag == null;

  /// Whether this node shows the same as [other]: same tag, text and
  /// attributes, and children that are the very same objects.
  bool sameAs(VNode other) {
    if (id != other.id || tag != other.tag || text != other.text) return false;
    if (attributes.length != other.attributes.length) return false;
    for (final entry in attributes.entries) {
      if (other.attributes[entry.key] != entry.value) return false;
    }
    if (children.length != other.children.length) return false;
    for (var i = 0; i < children.length; i++) {
      if (!identical(children[i], other.children[i])) return false;
    }
    return true;
  }

  /// The node in rrweb's serialized form. A full snapshot nests the whole
  /// subtree; a mutation adds every node on its own, so it leaves the
  /// children out.
  Map<String, Object?> serialize({bool withChildren = true}) {
    if (isText) return {'type': 3, 'textContent': text, 'id': id};
    return {
      'type': 2,
      'tagName': tag,
      'attributes': attributes,
      'childNodes': withChildren
          ? [for (final child in children) child.serialize()]
          : const [],
      'id': id,
    };
  }
}

/// Ids of the document skeleton around the captured screen.
const int documentNodeId = 1;
const int _doctypeNodeId = 2;
const int _htmlNodeId = 3;
const int _headNodeId = 4;
const int _charsetNodeId = 5;
const int _styleNodeId = 6;
const int _bodyNodeId = 7;

/// The element that holds the screen; every captured node is inside it.
const int screenNodeId = 8;

/// The first id handed to a captured node.
const int firstCapturedNodeId = 16;

/// The rrweb document of a full snapshot, with [screen] inside its body.
Map<String, Object?> serializeDocument(VNode screen) => {
      'type': 0,
      'id': documentNodeId,
      'childNodes': [
        {
          'type': 1,
          'name': 'html',
          'publicId': '',
          'systemId': '',
          'id': _doctypeNodeId,
        },
        {
          'type': 2,
          'tagName': 'html',
          'attributes': const <String, String>{},
          'id': _htmlNodeId,
          'childNodes': [
            {
              'type': 2,
              'tagName': 'head',
              'attributes': const <String, String>{},
              'id': _headNodeId,
              'childNodes': [
                {
                  'type': 2,
                  'tagName': 'meta',
                  'attributes': const {'charset': 'utf-8'},
                  'childNodes': const [],
                  'id': _charsetNodeId,
                },
                {
                  'type': 2,
                  'tagName': 'style',
                  'attributes': const {'_cssText': wireframeCss},
                  'childNodes': const [],
                  'id': _styleNodeId,
                },
              ],
            },
            {
              'type': 2,
              'tagName': 'body',
              'attributes': const <String, String>{},
              'id': _bodyNodeId,
              'childNodes': [screen.serialize()],
            },
          ],
        },
      ],
    };
