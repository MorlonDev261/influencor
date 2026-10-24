/// What the in-app / native file picker should select.
enum PickMode {
  /// Any files (multi-select when allowed).
  files,

  /// Image files only (multi-select when allowed).
  imageFiles,

  /// Image and video files only (multi-select when allowed).
  mediaFiles,

  /// A single directory.
  directory,
}
