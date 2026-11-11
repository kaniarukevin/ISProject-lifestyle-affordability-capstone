import 'package:flutter/material.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

/// Google requires its own rendered button on the web: it is what starts the sign-in, and its look is fixed by
/// Google's branding rules (the "G" has to keep its own colours on a light, dark or neutral button, and the rules
/// have to be followed for the app to pass verification). So the button stays Google's light pill, and Tosha's
/// lime goes around it in [GoogleButton] instead.
Widget googleSignInButton() => LayoutBuilder(
      builder: (context, box) => web.renderButton(
        configuration: web.GSIButtonConfiguration(
          type: web.GSIButtonType.standard,
          theme: web.GSIButtonTheme.outline,
          size: web.GSIButtonSize.large,
          text: web.GSIButtonText.continueWith,
          shape: web.GSIButtonShape.pill,
          logoAlignment: web.GSIButtonLogoAlignment.left,
          minimumWidth: box.maxWidth.isFinite ? (box.maxWidth - 2).clamp(200.0, 400.0) : 320.0,
        ),
      ),
    );
