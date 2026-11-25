import 'package:flutter/material.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

/// Google requires its own rendered button on the web: it is what starts the sign-in, and its look comes from
/// Google's presets (branding rules). 25 Nov: the round "G" icon preset, like the reference design: black in dark
/// mode, outlined white in light mode.
Widget googleSignInButton({bool dark = false}) => web.renderButton(
      configuration: web.GSIButtonConfiguration(
        type: web.GSIButtonType.icon,
        theme: dark ? web.GSIButtonTheme.filledBlack : web.GSIButtonTheme.outline,
        size: web.GSIButtonSize.large,
        shape: web.GSIButtonShape.circle,
      ),
    );
