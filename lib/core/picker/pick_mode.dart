/// What the in-app / native file picker should select.
enum PickMode {
  /// Any files (multi-select when allowed).
  files,

  /// Image files only (multi-select when allowed).
  imageFiles,

  /// Image and video files only (multi-select when allowed).
  mediaFiles,

  /// `.json` files only (multi-select when allowed), always through the
  /// platform-native picker so the extension filter applies.
  jsonFiles,

  /// A single directory.
  directory,
}
