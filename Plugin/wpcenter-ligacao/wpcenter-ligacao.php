<?php
/**
 * Plugin Name: WP Center Ligação
 * Description: Deixa a app WP Center (Mac) ver o estado deste site, atualizar plugins, temas, traduções e o WordPress, e abrir o WP Admin já com sessão iniciada. Não tem definições: a ligação aprova-se no navegador e revoga-se em Utilizadores → Perfil → Palavras-passe de aplicação.
 * Version: 1.3.0
 * Requires at least: 5.6
 * Requires PHP: 7.4
 * Author: WP Center
 * License: GPL-2.0-or-later
 */

defined( 'ABSPATH' ) || exit;

// Rotas da API, só para quem pode atualizar plugins (administradores). A autenticação é a do WordPress:
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
		register_rest_route(
			'wpcenter/v1',
			'/self-update',
			array(
				'methods'             => 'POST',
				'callback'            => 'wpcenter_ligacao_self_update',
				'permission_callback' => function () {
					return current_user_can( 'install_plugins' );
				},
			)
		);
		register_rest_route(
			'wpcenter/v1',
			'/login',
			array(
				'methods'             => 'POST',
				'callback'            => 'wpcenter_ligacao_login_code',
				'permission_callback' => $allowed,
			)
		);
	}
);

/**
 * Código para o botão WP Admin da app: de uso único, válido 60 segundos e guardado só como hash SHA-256,
 * como a entrada automática dos sites locais. A app abre /wp-admin/?wpcenter_entrar=<código>.
 */
function wpcenter_ligacao_login_code() {
	if ( ! is_ssl() && 'local' !== wp_get_environment_type() ) {
		return new WP_Error( 'wpcenter_https', 'A entrada automática só funciona por HTTPS.', array( 'status' => 403 ) );
	}
	$code = bin2hex( random_bytes( 32 ) );
	set_transient( 'wpcenter_entrar_' . hash( 'sha256', $code ), get_current_user_id(), 60 );
	return array( 'code' => $code );
}

add_action(
	'init',
	function () {
		if ( empty( $_GET['wpcenter_entrar'] ) || ! is_string( $_GET['wpcenter_entrar'] ) ) {
			return;
		}
		$key     = 'wpcenter_entrar_' . hash( 'sha256', wp_unslash( $_GET['wpcenter_entrar'] ) );
		$user_id = (int) get_transient( $key );
		delete_transient( $key ); // uso único, mesmo que algo falhe a seguir

		$user = $user_id ? get_user_by( 'id', $user_id ) : false;
		if ( ! $user || ! user_can( $user, 'update_plugins' ) ) {
			wp_safe_redirect( wp_login_url( admin_url() ) );
			exit;
		}

		wp_set_current_user( $user->ID );
		wp_set_auth_cookie( $user->ID, false, is_ssl() );
		do_action( 'wp_login', $user->user_login, $user );
		wp_safe_redirect( remove_query_arg( 'wpcenter_entrar' ) ); // sem o código no URL nem no histórico
		exit;
	},
	1
);

/**
 * A app envia o zip do plugin que traz dentro (corpo application/zip) quando este site tem uma versão mais antiga.
 * É o mesmo que Plugins → Adicionar → Carregar → "Substituir o atual pelo carregado", sem sair da app.
 */
function wpcenter_ligacao_self_update( WP_REST_Request $request ) {
	wpcenter_ligacao_load_admin();
	if ( 'direct' !== get_filesystem_method() || ! wp_is_file_mod_allowed( 'plugin_install' ) ) {
		return new WP_Error( 'wpcenter_not_writable', 'O servidor não deixa o WordPress instalar plugins daqui.', array( 'status' => 500 ) );
	}
	$zip = wp_tempnam( 'wpcenter-ligacao.zip' );
	file_put_contents( $zip, $request->get_body() );
	// Só este plugin: outra pasta dentro do zip seria outro plugin. Sem ZipArchive no servidor fica sem esta verificação
	// (quem tem install_plugins pode carregar qualquer plugin no WP Admin de qualquer forma).
	$foreign = false;
	if ( class_exists( 'ZipArchive' ) ) {
		$archive = new ZipArchive();
		$opened  = true === $archive->open( $zip );
		$foreign = ! $opened || 0 === $archive->numFiles;
		for ( $i = 0; ! $foreign && $i < $archive->numFiles; $i++ ) {
			$foreign = 0 !== strpos( $archive->getNameIndex( $i ), 'wpcenter-ligacao/' );
		}
		if ( $opened ) {
			$archive->close();
		}
	}
	if ( $foreign ) {
		wp_delete_file( $zip );
		return new WP_Error( 'wpcenter_bad_package', 'O pacote não é o plugin WP Center Ligação.', array( 'status' => 400 ) );
	}
	$skin   = new WP_Ajax_Upgrader_Skin();
	$result = ( new Plugin_Upgrader( $skin ) )->install( $zip, array( 'overwrite_package' => true ) );
	wp_delete_file( $zip );
	if ( ! $result || is_wp_error( $result ) ) {
		$message = is_wp_error( $result ) ? $result->get_error_message() : implode( ' ', (array) $skin->get_error_messages() );
		return new WP_Error( 'wpcenter_self_update', $message ? $message : 'Falhou a atualização do plugin.', array( 'status' => 500 ) );
	}
	// Continua ativo: a ativação guarda o caminho do ficheiro, que não mudou. O código novo só corre no pedido seguinte.
	return array( 'ok' => true );
}

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
		// Pacotes de idioma por atualizar (WordPress, plugins e temas), como o botão "Atualizar traduções".
		'translations' => count( wp_get_translation_updates() ),
		'checked'   => isset( $plugin_updates->last_checked ) ? (int) $plugin_updates->last_checked : null,
		'debug'     => defined( 'WP_DEBUG' ) && WP_DEBUG,
		'writable'  => 'direct' === get_filesystem_method(),
	);
}

/**
 * Atualiza com o atualizador do próprio WordPress, o mesmo do botão "Atualizar agora".
 * Corpo: {"plugins": ["pasta/ficheiro.php"], "themes": ["slug"], "core": true, "translations": true}
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

	// Depois do resto: um WordPress, plugin ou tema novo pode trazer traduções novas.
	if ( $request->get_param( 'translations' ) ) {
		$skin    = new WP_Ajax_Upgrader_Skin();
		$results = ( new Language_Pack_Upgrader( $skin ) )->bulk_upgrade();
		$failed  = array_filter(
			(array) $results,
			function ( $result ) {
				return ! $result || is_wp_error( $result );
			}
		);
		$collect( array( 'translations' => $failed ? reset( $failed ) : true ), $skin, 'Falhou a atualização das traduções.' );
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
