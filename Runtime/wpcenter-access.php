<?php
/**
 * Acesso ao wp-admin para o WP Center. Uso: wp eval-file wpcenter-access.php
 * Lê tudo do ambiente (nunca de argumentos, que ficam visíveis em `ps`):
 *   WPCENTER_ACTION   login | check | reset
 *   WPCENTER_USER     utilizador guardado na app
 *   WPCENTER_TOKEN    (login) código de uso único
 *   WPCENTER_PASS     (check/reset) palavra-passe guardada / nova
 * Responde com uma linha "WPCENTER_RESULT {json}".
 */

function wpcenter_reply( array $data ) {
	echo 'WPCENTER_RESULT ' . wp_json_encode( $data ) . "\n";
	exit( $data['ok'] ? 0 : 1 );
}

// O utilizador guardado, se ainda existir e for administrador; senão o primeiro administrador
// (depois de um restauro do WPvivid os utilizadores passam a ser os do site de origem).
$wpcenter_user = get_user_by( 'login', (string) getenv( 'WPCENTER_USER' ) );
if ( ! $wpcenter_user || ! user_can( $wpcenter_user, 'manage_options' ) ) {
	$admins        = get_users( array( 'role' => 'administrator', 'number' => 1, 'orderby' => 'ID', 'order' => 'ASC' ) );
	$wpcenter_user = $admins[0] ?? false;
}
if ( ! $wpcenter_user ) {
	wpcenter_reply( array( 'ok' => false, 'error' => 'Este site não tem nenhum administrador.' ) );
}

switch ( getenv( 'WPCENTER_ACTION' ) ) {
	case 'login':
		$token = (string) getenv( 'WPCENTER_TOKEN' );
		if ( strlen( $token ) < 32 ) {
			wpcenter_reply( array( 'ok' => false, 'error' => 'Código de entrada inválido.' ) );
		}
		set_transient( 'wpcenter_login_' . hash( 'sha256', $token ), $wpcenter_user->ID, 60 );
		wpcenter_reply( array( 'ok' => true, 'user' => $wpcenter_user->user_login ) );
		break;

	case 'check':
		$valid = $wpcenter_user->user_login === getenv( 'WPCENTER_USER' )
			&& wp_check_password( (string) getenv( 'WPCENTER_PASS' ), $wpcenter_user->user_pass, $wpcenter_user->ID );
		wpcenter_reply( array( 'ok' => true, 'valid' => $valid, 'user' => $wpcenter_user->user_login ) );
		break;

	case 'reset':
		$pass = (string) getenv( 'WPCENTER_PASS' );
		if ( strlen( $pass ) < 12 ) {
			wpcenter_reply( array( 'ok' => false, 'error' => 'Palavra-passe demasiado curta.' ) );
		}
		wp_set_password( $pass, $wpcenter_user->ID ); // termina também as sessões abertas desse utilizador
		wpcenter_reply( array( 'ok' => true, 'user' => $wpcenter_user->user_login ) );
		break;
}

wpcenter_reply( array( 'ok' => false, 'error' => 'Ação desconhecida.' ) );
