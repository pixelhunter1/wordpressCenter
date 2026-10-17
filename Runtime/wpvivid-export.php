<?php
/**
 * Exportar para cPanel: corre o backup do próprio WPvivid — o mesmo plugin que restaura no cPanel —
 * excluindo tudo o que só faz sentido no Mac. Uso: wp eval-file wpvivid-export.php
 * Escreve no fim uma linha "WPCENTER_RESULT {json}" com a pasta e os ficheiros gerados.
 */

// Mensagens na língua da app (WPCENTER_LANG, posto pelo WP Center): en ou pt.
if ( ! function_exists( 'wpcenter_t' ) ) {
	function wpcenter_t( $pt, $en ) {
		return 'en' === getenv( 'WPCENTER_LANG' ) ? $en : $pt;
	}
}


if ( empty( $GLOBALS['wpvivid_plugin'] ) ) {
	echo 'WPCENTER_RESULT ' . json_encode( array( 'ok' => false, 'error' => wpcenter_t( 'O plugin WPvivid não está ativo neste site.', 'The WPvivid plugin is not active on this site.' ) ) ) . "\n";
	exit( 1 );
}

$wpcenter_content = str_replace( '\\', '/', WP_CONTENT_DIR );

// Só existe no Mac: restos do Studio e ferramentas de desenvolvimento.
$wpcenter_local_only = array(
	'database/',                               // base de dados SQLite antiga do Studio
	'mu-plugins/sqlite-database-integration/', // plugin SQLite do Studio
	'mu-plugins/99-studio-loader.php',         // carregador de mu-plugins do Studio
	'mu-plugins/dev-',                         // mu-plugins de desenvolvimento (dev-*.php, p.ex. Mailpit)
	'mu-plugins/wpcenter-',                    // entrada automática do WP Center (só local)
);
// Drop-in SQLite (Studio/WP Center): no cPanel o WordPress tem de usar MySQL/MariaDB.
if ( is_file( WP_CONTENT_DIR . '/db.php' ) && false !== strpos( (string) file_get_contents( WP_CONTENT_DIR . '/db.php' ), 'SQLITE_DB_DROPIN' ) ) {
	$wpcenter_local_only[] = 'db.php';
}

// Ficheiros na raiz do site para agentes de IA (WP Center e Studio). Um AGENTS.md dentro de um tema continua incluído.
// O .mcp.json tem o endereço localhost e uma palavra-passe de aplicação deste Mac.
$wpcenter_root       = str_replace( '\\', '/', rtrim( ABSPATH, '/\\' ) );
$wpcenter_root_files = array( 'AGENTS.md', 'CLAUDE.md', 'WPCENTER.md', 'STUDIO.md', '.mcp.json' );

// O WPvivid junta raiz e nome com "/" mesmo quando a raiz já termina em "/" (…/site//AGENTS.md): daí o "/+".
add_filter(
	'wpvivid_get_backup_exclude_regex',
	function ( $regex, $type ) use ( $wpcenter_content, $wpcenter_local_only, $wpcenter_root, $wpcenter_root_files ) {
		if ( WPVIVID_BACKUP_TYPE_CONTENT === $type ) {
			foreach ( $wpcenter_local_only as $path ) {
				$regex[] = '#^' . preg_quote( $wpcenter_content, '#' ) . '/+' . preg_quote( $path, '#' ) . '#';
			}
		}
		if ( WPVIVID_BACKUP_TYPE_CORE === $type ) {
			foreach ( $wpcenter_root_files as $file ) {
				$regex[] = '#^' . preg_quote( $wpcenter_root, '#' ) . '/+' . preg_quote( $file, '#' ) . '$#';
			}
		}
		return $regex;
	},
	99,
	2
);

// O WPvivid apaga os backups locais mais antigos quando passa do limite: uma exportação nunca apaga backups do utilizador.
add_filter( 'wpvivid_get_oldest_backup_ids', '__return_empty_array', 99 );

$wpcenter_options = array(
	'backup_files' => 'files+db',
	'local'        => '1',
	'remote'       => '0',
	'ismerge'      => '1', // um único zip "backup_all", como num backup manual
	'lock'         => '0',
	'type'         => 'Manual',
	'action'       => 'backup',
);

$wpvivid = $GLOBALS['wpvivid_plugin'];

// O WPvivid só regista os passos do backup (dump da base de dados, conclusão da tarefa…) no painel (is_admin()).
// Carregamos essa parte como acontece ao carregar em "Backup Now" no wp-admin.
if ( ! is_admin() ) {
	require_once ABSPATH . 'wp-admin/includes/admin.php';
	$wpvivid->load_admin();
}

$ret = $wpvivid->check_backup_option( $wpcenter_options, 'Manual' );
if ( WPVIVID_SUCCESS === $ret['result'] ) {
	$ret = $wpvivid->pre_backup( $wpcenter_options );
}
if ( 'success' !== $ret['result'] ) {
	echo 'WPCENTER_RESULT ' . json_encode( array( 'ok' => false, 'error' => $ret['error'] ?? wpcenter_t( 'O WPvivid recusou o backup.', 'WPvivid refused the backup.' ) ) ) . "\n";
	exit( 1 );
}
$wpcenter_task_id = $ret['task_id'];

// O WPvivid termina com die() no fim do backup: o resultado é recolhido aqui.
// Os ficheiros passam para a pasta de exportação (WPCENTER_EXPORT_DIR) e a exportação sai da lista de backups do site.
register_shutdown_function(
	function () use ( $wpcenter_task_id, $wpcenter_local_only, $wpcenter_root_files ) {
		$source = str_replace( '\\', '/', WP_CONTENT_DIR . '/' . WPvivid_Setting::get_backupdir() );
		$target = (string) getenv( 'WPCENTER_EXPORT_DIR' );
		$paths  = glob( $source . '/*' . $wpcenter_task_id . '*.zip' ) ?: array();
		$task   = WPvivid_taskmanager::get_task( $wpcenter_task_id );
		$error  = is_array( $task ) && ! empty( $task['status']['error'] ) ? $task['status']['error'] : '';
		if ( empty( $paths ) && '' === $error ) {
			$error = 'O WPvivid não gerou nenhum ficheiro.';
		}

		if ( '' === $error && '' !== $target ) {
			wp_mkdir_p( $target );
			foreach ( $paths as $path ) {
				if ( ! rename( $path, $target . '/' . basename( $path ) ) ) {
					$error = 'Não foi possível mover ' . basename( $path ) . ' para ' . $target . '.';
					break;
				}
			}
			if ( '' === $error ) {
				WPvivid_Backuplist::delete_backup( $wpcenter_task_id );
				WPvivid_taskmanager::delete_task( $wpcenter_task_id );
			}
		}

		echo "\nWPCENTER_RESULT " . json_encode(
			array(
				'ok'       => '' === $error,
				'error'    => $error,
				'dir'      => '' === $error && '' !== $target ? $target : $source,
				'files'    => array_values( array_map( 'basename', $paths ) ),
				'excluded' => array_merge( $wpcenter_local_only, $wpcenter_root_files ),
			)
		) . "\n";
	}
);

$wpvivid->backup( $wpcenter_task_id );
