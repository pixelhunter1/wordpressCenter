<?php
/**
 * Plugin Name: WP Center Ligação
 * Description: Deixa a app WP Center (Mac) ver o estado deste site e atualizar plugins, temas e o WordPress. Não tem definições: a ligação aprova-se no navegador e revoga-se em Utilizadores → Perfil → Palavras-passe de aplicação.
 * Version: 1.1.1
 * Requires at least: 5.6
 * Requires PHP: 7.4
 * Author: WP Center
 * License: GPL-2.0-or-later
 */

defined( 'ABSPATH' ) || exit;

// Duas rotas da API, só para quem pode atualizar plugins (administradores). A autenticação é a do WordPress:
// a Palavra-passe de aplicação "WP Center", criada quando o utilizador aprova a ligação no navegador.
add_action(
	'rest_api_init',
	function () {
		$allowed = function () {
			return current_user_can( 'update_plugins' );
		};
		register_rest_route(
			'wpcenter/v1',
			'/status',
			array(
				'methods'             => 'GET',
				'callback'            => 'wpcenter_ligacao_status',
				'permission_callback' => $allowed,
			)
		);
		register_rest_route(
			'wpcenter/v1',
			'/update',
			array(
				'methods'             => 'POST',
				'callback'            => 'wpcenter_ligacao_update',
				'permission_callback' => $allowed,
			)
		);
	}
);

function wpcenter_ligacao_load_admin() {
	require_once ABSPATH . 'wp-admin/includes/admin.php';
	require_once ABSPATH . 'wp-admin/includes/class-wp-upgrader.php';
}

/** Versões, plugins e temas, com as atualizações disponíveis. force=1 volta a perguntar ao wordpress.org já. */
function wpcenter_ligacao_status( WP_REST_Request $request ) {
	wpcenter_ligacao_load_admin();
	if ( $request->get_param( 'force' ) ) {
		wp_clean_update_cache();
	}
	// Cada uma só contacta o wordpress.org se a última verificação tiver mais de 12 horas (ou se forçado acima).
	wp_version_check();
	wp_update_plugins();
	wp_update_themes();

	$core = null;
	foreach ( (array) get_core_updates() as $offer ) {
		if ( isset( $offer->response ) && 'upgrade' === $offer->response ) {
			$core = $offer->current;
			break;
		}
	}

	$plugin_updates = get_site_transient( 'update_plugins' );
	$plugins        = array();
	foreach ( get_plugins() as $file => $data ) {
		$offer     = $plugin_updates->response[ $file ] ?? null;
		$plugins[] = array(
			'file'    => $file,
			'name'    => $data['Name'],
			'version' => $data['Version'],
			'active'  => is_plugin_active( $file ),
			'update'  => $offer->new_version ?? null,
		);
	}

	$theme_updates = get_site_transient( 'update_themes' );
	$current       = get_stylesheet();
	$themes        = array();
	foreach ( wp_get_themes() as $slug => $theme ) {
		$themes[] = array(
			'slug'    => $slug,
			'name'    => $theme->get( 'Name' ),
			'version' => $theme->get( 'Version' ),
			'active'  => $slug === $current,
			'update'  => $theme_updates->response[ $slug ]['new_version'] ?? null,
		);
	}

	$data = get_plugin_data( __FILE__, false, false );
	return array(
		'plugin'    => $data['Version'],
		'name'      => get_bloginfo( 'name' ),
		'url'       => home_url(),
		'icon'      => get_site_icon_url( 512 ) ? get_site_icon_url( 512 ) : null,
		'wordpress' => get_bloginfo( 'version' ),
		'php'       => PHP_VERSION,
		'core'      => $core,
		'plugins'   => $plugins,
		'themes'    => $themes,
		'checked'   => isset( $plugin_updates->last_checked ) ? (int) $plugin_updates->last_checked : null,
		'debug'     => defined( 'WP_DEBUG' ) && WP_DEBUG,
		'writable'  => 'direct' === get_filesystem_method(),
	);
}

/**
 * Atualiza com o atualizador do próprio WordPress, o mesmo do botão "Atualizar agora".
 * Corpo: {"plugins": ["pasta/ficheiro.php"], "themes": ["slug"], "core": true}
 * Devolve o estado novo e os erros de cada item que falhou.
 */
function wpcenter_ligacao_update( WP_REST_Request $request ) {
	wpcenter_ligacao_load_admin();
	if ( 'direct' !== get_filesystem_method() ) {
		return new WP_Error( 'wpcenter_not_writable', 'O servidor não deixa o WordPress escrever nos próprios ficheiros (pede FTP), por isso não é possível atualizar daqui.', array( 'status' => 500 ) );
	}
	if ( function_exists( 'set_time_limit' ) ) {
		set_time_limit( 600 );
	}
	wp_update_plugins();
	wp_update_themes();

	$errors  = array();
	$collect = function ( $results, $skin, $label ) use ( &$errors ) {
		foreach ( (array) $results as $item => $result ) {
			if ( is_wp_error( $result ) ) {
				$errors[ $item ] = $result->get_error_message();
			} elseif ( ! $result ) {
				$messages        = $skin->get_error_messages();
				$errors[ $item ] = $messages ? $messages : $label;
			}
		}
	};

	$plugins = array_values( array_filter( (array) $request->get_param( 'plugins' ), 'is_string' ) );
	if ( $plugins ) {
		$skin = new WP_Ajax_Upgrader_Skin();
		$collect( ( new Plugin_Upgrader( $skin ) )->bulk_upgrade( $plugins ), $skin, 'Falhou a atualização do plugin.' );
	}

	$themes = array_values( array_filter( (array) $request->get_param( 'themes' ), 'is_string' ) );
	if ( $themes ) {
		$skin = new WP_Ajax_Upgrader_Skin();
		$collect( ( new Theme_Upgrader( $skin ) )->bulk_upgrade( $themes ), $skin, 'Falhou a atualização do tema.' );
	}

	$new_core = null;
	if ( $request->get_param( 'core' ) ) {
		wp_version_check( array(), true );
		$offer = null;
		foreach ( (array) get_core_updates() as $candidate ) {
			if ( isset( $candidate->response ) && 'upgrade' === $candidate->response ) {
				$offer = $candidate;
				break;
			}
		}
		if ( $offer ) {
			$skin   = new WP_Ajax_Upgrader_Skin();
			$result = ( new Core_Upgrader( $skin ) )->upgrade( $offer, array( 'attempt_rollback' => true ) );
			$collect( array( 'wordpress' => $result ), $skin, 'Falhou a atualização do WordPress.' );
			$new_core = is_string( $result ) ? $result : null;
		}
	}

	// Estado fresco: os atualizadores limpam a cache das atualizações e o wordpress.org volta a ser consultado.
	$status = wpcenter_ligacao_status( new WP_REST_Request( 'GET' ) );
	if ( $new_core ) {
		// Este pedido ainda tem a versão antiga em memória; o WordPress novo só arranca no pedido seguinte.
		$status['wordpress'] = $new_core;
		$status['core']      = null;
	}
	$status['errors'] = (object) $errors;
	return $status;
}
