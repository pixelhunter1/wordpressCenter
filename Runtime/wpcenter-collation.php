<?php
/**
 * Colações exclusivas do MySQL 8 (utf8mb4_0900_*): o MariaDB 10.11 — o padrão do cPanel — recusa-as
 * ("Unknown collation"), por isso um restauro do WPvivid falha nessas tabelas.
 * Uso: wp eval-file wpcenter-collation.php, com WPCENTER_ACTION = check | convert.
 * Responde com uma linha "WPCENTER_RESULT {json}".
 */

// Mensagens na língua da app (WPCENTER_LANG, posto pelo WP Center): en ou pt.
if ( ! function_exists( 'wpcenter_t' ) ) {
	function wpcenter_t( $pt, $en ) {
		return 'en' === getenv( 'WPCENTER_LANG' ) ? $en : $pt;
	}
}


global $wpdb;

function wpcenter_reply( array $data ) {
	echo 'WPCENTER_RESULT ' . wp_json_encode( $data ) . "\n";
	exit( $data['ok'] ? 0 : 1 );
}

// Tabelas cuja colação por omissão, ou a de alguma coluna, só existe no MySQL 8.
$tables = $wpdb->get_col(
	"SELECT TABLE_NAME FROM information_schema.TABLES
	  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE' AND TABLE_COLLATION LIKE '%\\_0900\\_%'
	 UNION
	 SELECT DISTINCT TABLE_NAME FROM information_schema.COLUMNS
	  WHERE TABLE_SCHEMA = DATABASE() AND COLLATION_NAME LIKE '%\\_0900\\_%'"
);
if ( $wpdb->last_error ) {
	wpcenter_reply( array( 'ok' => false, 'error' => $wpdb->last_error ) );
}
sort( $tables );

if ( 'convert' === getenv( 'WPCENTER_ACTION' ) ) {
	foreach ( $tables as $table ) {
		// CONVERT TO muda a tabela e todas as colunas de texto; os dados mantêm-se.
		$quoted = '`' . str_replace( '`', '``', $table ) . '`';
		if ( false === $wpdb->query( "ALTER TABLE $quoted CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" ) ) {
			wpcenter_reply( array( 'ok' => false, 'error' => sprintf( wpcenter_t( 'Não foi possível converter %s: ', 'Could not convert %s: ' ), $table ) . $wpdb->last_error, 'tables' => $tables ) );
		}
	}
	wpcenter_reply( array( 'ok' => true, 'tables' => array(), 'converted' => $tables ) );
}

wpcenter_reply( array( 'ok' => true, 'tables' => $tables ) );
