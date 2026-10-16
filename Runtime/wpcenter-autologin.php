<?php
/**
 * Plugin Name: WP Center — entrada automática (só local)
 * Description: Permite ao WP Center abrir o wp-admin já com sessão iniciada. Só funciona em ambiente local, a partir do próprio Mac, com um código de uso único válido 60 segundos. Não é incluído na exportação para o cPanel.
 *
 * Instalado e atualizado pelo WP Center em wp-content/mu-plugins/. O código é criado pela app via WP-CLI
 * (só quem tem acesso aos ficheiros do site o consegue criar) e guardado apenas como hash SHA-256.
 */

if ( ! function_exists( 'wp_get_environment_type' ) || 'local' !== wp_get_environment_type() ) {
	return;
}

add_action(
	'init',
	function () {
		if ( empty( $_GET['wpcenter_login'] ) || ! is_string( $_GET['wpcenter_login'] ) ) {
			return;
		}
		// Só pedidos feitos no próprio Mac.
		if ( ! in_array( $_SERVER['REMOTE_ADDR'] ?? '', array( '127.0.0.1', '::1' ), true ) ) {
			return;
		}

		$key     = 'wpcenter_login_' . hash( 'sha256', wp_unslash( $_GET['wpcenter_login'] ) );
		$user_id = (int) get_transient( $key );
		delete_transient( $key ); // uso único, mesmo que algo falhe a seguir

		$user = $user_id ? get_user_by( 'id', $user_id ) : false;
		if ( ! $user || ! user_can( $user, 'manage_options' ) ) {
			wp_safe_redirect( wp_login_url( admin_url() ) );
			exit;
		}

		wp_set_current_user( $user->ID );
		wp_set_auth_cookie( $user->ID, false );
		do_action( 'wp_login', $user->user_login, $user );
		wp_safe_redirect( admin_url() ); // tira o código do URL
		exit;
	},
	1
);
