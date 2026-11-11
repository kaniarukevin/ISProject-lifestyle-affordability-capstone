import 'package:flutter/material.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

/// Google requires its own rendered button on the web; it is what starts the sign-in. Configured to sit with
/// Tosha's own buttons: black, full width and pill-shaped, like every other primary button in the app.
Widget googleSignInButton() => SizedBox(
      height: 48,
      child: web.renderButton(
        configuration: web.GSIButtonConfiguration(
          type: web.GSIButtonType.standard,
          theme: web.GSIButtonTheme.filledBlack,
          size: web.GSIButtonSize.large,
          text: web.GSIButtonText.continueWith,
          shape: web.GSIButtonShape.pill,
          logoAlignment: web.GSIButtonLogoAlignment.left,
          minimumWidth: 320,
        ),
      ),
    );
