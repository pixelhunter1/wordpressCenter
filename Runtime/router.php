<?php
// Router for PHP's built-in server; mirrors WordPress's default .htaccess.
$root = realpath( $_SERVER['DOCUMENT_ROOT'] );
$path = rawurldecode( parse_url( $_SERVER['REQUEST_URI'], PHP_URL_PATH ) );
$file = $root . $path;

if ( '/' !== $path && is_file( $file ) ) {
	if ( 'php' !== strtolower( pathinfo( $file, PATHINFO_EXTENSION ) ) ) {
		return false; // static asset, served by the built-in server
	}
	$script = $path;
} elseif ( is_dir( $file ) && is_file( rtrim( $file, '/' ) . '/index.php' ) ) {
	$script = rtrim( $path, '/' ) . '/index.php';
} else {
	$script = '/index.php';
}

$_SERVER['SCRIPT_NAME']     = $script;
$_SERVER['PHP_SELF']        = $script;
$_SERVER['SCRIPT_FILENAME'] = $root . $script;
chdir( dirname( $root . $script ) );
require $root . $script;
