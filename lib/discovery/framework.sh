# shellcheck shell=bash
#
# framework.sh — emits the remote-side shell snippet that detects the project
# type. The snippet runs on the managed server (modern bash) and prints
# `framework=<type>` plus, for JS apps, leaves $fw set for later snippets.
#
# Detection order matters: Statamic & Laravel both ship `artisan`, and JS
# meta-frameworks (Next/Nuxt) also have a generic package.json — so the more
# specific signal must win.

_disc_framework_snippet() {
cat <<'SNIPPET'
# --- framework detection ------------------------------------------------
_has_glob() { local g; for g in $1; do [ -e "$g" ] && return 0; done; return 1; }
_composer_has() { [ -f "$APP_ROOT/composer.json" ] && grep -q "\"$1\"" "$APP_ROOT/composer.json" 2>/dev/null; }
_pkg_has() { [ -f "$APP_ROOT/package.json" ] && grep -q "\"$1\"" "$APP_ROOT/package.json" 2>/dev/null; }

fw=""
if   [ -f "$APP_ROOT/wp-config.php" ] || [ -f "$ROOT/wp-config.php" ]; then fw=wordpress
elif _composer_has "statamic/cms";                                       then fw=statamic
elif [ -f "$APP_ROOT/artisan" ];                                          then fw=laravel
elif [ -f "$APP_ROOT/bin/console" ] && _composer_has "symfony/";          then fw=symfony
elif _pkg_has next || _has_glob "$APP_ROOT/next.config.*";                then fw=nextjs
elif _pkg_has nuxt || _has_glob "$APP_ROOT/nuxt.config.*";                then fw=nuxt
elif _pkg_has vue;                                                        then fw=vue
elif _pkg_has react;                                                      then fw=react
elif [ -f "$APP_ROOT/package.json" ];                                     then fw=nodejs
elif _has_glob "$ROOT/index.html" || _has_glob "$ROOT/index.htm";         then fw=static
else fw=""   # caller will prompt (likely reverse_proxy)
fi
echo "framework=$fw"
SNIPPET
}
