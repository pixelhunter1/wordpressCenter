<?php
/**
 * Plugin Name: WP Center — emails para o Mailpit (só local)
 * Description: Entrega o wp_mail() ao Mailpit incluído no WP Center (SMTP 127.0.0.1:1025), para ver os emails do site no botão "Emails" sem nada sair para a internet. Não é incluído na exportação para o cPanel.
 *
 * Sem isto, o PHP entrega ao /usr/sbin/sendmail, que no macOS não está a correr: os emails perdem-se em silêncio.
 * Só atua em ambiente local e com o Mailpit a atender; caso contrário o WordPress segue como antes.
 */

if ( ! function_exists( 'wp_get_environment_type' ) || 'local' !== wp_get_environment_type() ) {
	return;
}

// O remetente por omissão é wordpress@localhost: sem domínio de topo, o PHPMailer recusa-o antes de enviar.
add_filter(
	'wp_mail_from',
	function ( $from ) {
		return str_ends_with( $from, '@localhost' ) ? 'wordpress@localhost.test' : $from;
	}
);

add_action(
	'phpmailer_init',
	function ( $phpmailer ) {
		// Mailpit parado: sem esta sondagem o PHPMailer bloqueava o pedido à espera de uma ligação que ninguém atende.
		$socket = @fsockopen( '127.0.0.1', 1025, $errno, $errstr, 0.5 );
		if ( ! $socket ) {
			return;
		}
		fclose( $socket );

		$phpmailer->isSMTP();
		$phpmailer->Host        = '127.0.0.1';
		$phpmailer->Port        = 1025;
		$phpmailer->SMTPAuth    = false;
		$phpmailer->SMTPSecure  = '';
		$phpmailer->SMTPAutoTLS = false;
		$phpmailer->Timeout     = 5;
	}
);
