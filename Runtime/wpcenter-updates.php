<?php
/**
 * Plugin Name: WP Center — fila de atualizações (só local)
 * Description: Corrige um erro do WordPress 7.1 que, quando um plugin falha a atualizar, deixa os seguintes em "A atualizar…" para sempre. Não é incluído na exportação para o cPanel.
 *
 * Na página Plugins, o updatePluginError do wp-admin/js/updates.js lê $card.attr( 'id' ), mas $card só existe na página
 * de instalar plugins. O TypeError salta o ajaxAlways, a fila fica trancada (wp.updates.ajaxLocked) e nada mais avança.
 * ponytail: remendo ao JS do núcleo; retirar quando o WordPress corrigir o updatePluginError.
 */

if ( ! function_exists( 'wp_get_environment_type' ) || 'local' !== wp_get_environment_type() ) {
	return;
}

add_action(
	'admin_enqueue_scripts',
	function () {
		// Só é impresso onde o script 'updates' é usado. Engole o erro para o resto da fila correr.
		wp_add_inline_script(
			'updates',
			'( function ( updates ) {
				var original = updates.updatePluginError;
				updates.updatePluginError = function () {
					try {
						return original.apply( this, arguments );
					} catch ( error ) {
						window.console && console.error( error );
					}
				};
			} )( window.wp.updates );'
		);
	}
);
