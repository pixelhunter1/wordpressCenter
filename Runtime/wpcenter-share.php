<?php
/**
 * Plugin Name: WP Center — partilha por link (só local)
 * Description: Quando o site é aberto pelo link de partilha do WP Center (Cloudflare Quick Tunnel), serve-o com o endereço desse link em vez de localhost. Não altera a base de dados. Não é incluído na exportação para o cPanel.
 */

if ( ! function_exists( 'wp_get_environment_type' ) || 'local' !== wp_get_environment_type() ) {
	return;
}

// O cloudflared liga-se ao site a partir do próprio Mac e mantém o Host público do link.
$wpcenter_host = strtolower( $_SERVER['HTTP_HOST'] ?? '' );
if ( ! preg_match( '/^[a-z0-9-]+\.trycloudflare\.com$/', $wpcenter_host )
	|| ! in_array( $_SERVER['REMOTE_ADDR'] ?? '', array( '127.0.0.1', '::1' ), true ) ) {
	return;
}

$_SERVER['HTTPS'] = 'on'; // o link é https: sem isto o WordPress gerava ligações http e cookies sem Secure

$wpcenter_home   = wp_parse_url( get_option( 'home' ) );
$wpcenter_local  = $wpcenter_home['scheme'] . '://' . $wpcenter_home['host'] . ( isset( $wpcenter_home['port'] ) ? ':' . $wpcenter_home['port'] : '' );
$wpcenter_public = 'https://' . $wpcenter_host;

defined( 'WP_HOME' ) || define( 'WP_HOME', str_replace( $wpcenter_local, $wpcenter_public, get_option( 'home' ) ) );
defined( 'WP_SITEURL' ) || define( 'WP_SITEURL', str_replace( $wpcenter_local, $wpcenter_public, get_option( 'siteurl' ) ) );

// URLs já calculados com localhost (conteúdo, WP_CONTENT_URL, JSON escapado): trocados só na resposta.
// Com HTTPS ligado o WordPress passa alguns a https://localhost:…, por isso os dois esquemas.
$wpcenter_origin = substr( $wpcenter_local, strpos( $wpcenter_local, '://' ) ); // ://localhost:PORTA
$wpcenter_from   = array( 'http' . $wpcenter_origin, 'https' . $wpcenter_origin );
$wpcenter_from   = array_merge( $wpcenter_from, str_replace( '/', '\/', $wpcenter_from ) );
$wpcenter_to     = array( $wpcenter_public, $wpcenter_public, str_replace( '/', '\/', $wpcenter_public ), str_replace( '/', '\/', $wpcenter_public ) );
$wpcenter_swap   = function ( $text ) use ( $wpcenter_from, $wpcenter_to ) {
	return str_replace( $wpcenter_from, $wpcenter_to, $text );
};
add_filter( 'wp_redirect', $wpcenter_swap );
ob_start( $wpcenter_swap );
