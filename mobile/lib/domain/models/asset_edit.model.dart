import "package:openapi/api.dart" show CropParameters, MirrorParameters, RotateParameters, TrimParameters;

// Persisted by index in the local database, so new actions must be appended
enum AssetEditAction { rotate, crop, mirror, other, trim }

sealed class AssetEdit {
  const AssetEdit();
}

class CropEdit extends AssetEdit {
  final CropParameters parameters;

  const CropEdit(this.parameters);
}

class RotateEdit extends AssetEdit {
  final RotateParameters parameters;

  const RotateEdit(this.parameters);
}

class MirrorEdit extends AssetEdit {
  final MirrorParameters parameters;

  const MirrorEdit(this.parameters);
}

class TrimEdit extends AssetEdit {
  final TrimParameters parameters;

  const TrimEdit(this.parameters);
}
