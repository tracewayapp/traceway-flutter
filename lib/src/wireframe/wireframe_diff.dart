import 'vnode.dart';

/// The data of an rrweb mutation event (`IncrementalSource.Mutation`) that
/// turns the screen [before] into [after], or null when both show the same.
/// Both trees are rooted at the same node.
///
/// rrweb's replayer applies the removes first, then the adds, then text and
/// attribute changes. An add builds only its own node, never the node's
/// children, so a new subtree is added node by node, parent first, and
/// siblings from the last to the first: each add's `nextId` names a node
/// that is already on the page. A node that moved, to another parent or
/// among its siblings, is removed and added again with its whole subtree.
Map<String, Object?>? diffScreens(VNode before, VNode after) {
  if (identical(before, after)) return null;
  final diff = _Diff();
  diff.node(before, after);
  if (diff.isEmpty) return null;
  return {
    'source': 0,
    'texts': diff.texts,
    'attributes': diff.attributes,
    'removes': diff.removes,
    'adds': diff.adds,
  };
}

class _Diff {
  final List<Map<String, Object?>> texts = [];
  final List<Map<String, Object?>> attributes = [];
  final List<Map<String, Object?>> removes = [];
  final List<Map<String, Object?>> adds = [];

  bool get isEmpty =>
      texts.isEmpty && attributes.isEmpty && removes.isEmpty && adds.isEmpty;

  /// [before] and [after] are the same node (same id and kind) in the two
  /// frames.
  void node(VNode before, VNode after) {
    if (identical(before, after)) return;
    if (after.isText) {
      if (before.text != after.text) {
        texts.add({'id': after.id, 'value': after.text});
      }
      return;
    }
    _attributes(before, after);
    _children(before, after);
  }

  void _attributes(VNode before, VNode after) {
    Map<String, String?>? changed;
    for (final entry in after.attributes.entries) {
      if (before.attributes[entry.key] != entry.value) {
        (changed ??= {})[entry.key] = entry.value;
      }
    }
    for (final key in before.attributes.keys) {
      if (!after.attributes.containsKey(key)) (changed ??= {})[key] = null;
    }
    if (changed != null) {
      attributes.add({'id': after.id, 'attributes': changed});
    }
  }

  void _children(VNode before, VNode after) {
    final oldChildren = before.children;
    final newChildren = after.children;
    if (identical(oldChildren, newChildren)) return;

    final oldIndex = <int, int>{
      for (var i = 0; i < oldChildren.length; i++) oldChildren[i].id: i,
    };
    // The children that are still here, as their old positions in their new
    // order. The longest increasing run of those stays in place; every other
    // one moved.
    final keptNew = <int>[];
    final keptOld = <int>[];
    for (var i = 0; i < newChildren.length; i++) {
      final at = oldIndex[newChildren[i].id];
      if (at != null && _sameKind(oldChildren[at], newChildren[i])) {
        keptNew.add(i);
        keptOld.add(at);
      }
    }
    final inPlace = <int>{};
    for (final k in _longestIncreasing(keptOld)) {
      inPlace.add(newChildren[keptNew[k]].id);
    }

    for (final child in oldChildren) {
      if (!inPlace.contains(child.id)) {
        removes.add({'parentId': before.id, 'id': child.id});
      }
    }
    for (final child in newChildren) {
      if (inPlace.contains(child.id)) {
        node(oldChildren[oldIndex[child.id]!], child);
      }
    }
    for (var i = newChildren.length - 1; i >= 0; i--) {
      final child = newChildren[i];
      if (inPlace.contains(child.id)) continue;
      _add(child, after.id,
          i + 1 < newChildren.length ? newChildren[i + 1].id : null);
    }
  }

  void _add(VNode node, int parentId, int? nextId) {
    adds.add({
      'parentId': parentId,
      'nextId': nextId,
      'node': node.serialize(withChildren: false),
    });
    final children = node.children;
    for (var i = children.length - 1; i >= 0; i--) {
      _add(children[i], node.id,
          i + 1 < children.length ? children[i + 1].id : null);
    }
  }

  static bool _sameKind(VNode a, VNode b) => a.tag == b.tag;
}

/// Positions in [values] of one longest strictly increasing subsequence.
List<int> _longestIncreasing(List<int> values) {
  if (values.isEmpty) return const [];
  // tails[k]: position of the smallest last value of a run of length k + 1.
  final tails = <int>[];
  final previous = List<int>.filled(values.length, -1);
  for (var i = 0; i < values.length; i++) {
    var lo = 0, hi = tails.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (values[tails[mid]] < values[i]) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0) previous[i] = tails[lo - 1];
    if (lo == tails.length) {
      tails.add(i);
    } else {
      tails[lo] = i;
    }
  }
  final out = List<int>.filled(tails.length, 0);
  var k = tails.last;
  for (var i = tails.length - 1; i >= 0; i--) {
    out[i] = k;
    k = previous[k];
  }
  return out;
}
