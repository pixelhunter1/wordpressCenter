<?php
/**
 * Testa a ligação a MySQL/MariaDB e, com DB_CREATE=1, cria a base de dados se não existir.
 * Tudo é lido do ambiente (DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME, DB_CREATE).
 * Responde sempre com uma linha JSON.
 */

// Mensagens na língua da app (WPCENTER_LANG, posto pelo WP Center): en ou pt.
if ( ! function_exists( 'wpcenter_t' ) ) {
	function wpcenter_t( $pt, $en ) {
		return 'en' === getenv( 'WPCENTER_LANG' ) ? $en : $pt;
	}
}


function reply( array $data ) {
	echo json_encode( $data );
	exit( $data['ok'] ? 0 : 1 );
}

$name = (string) getenv( 'DB_NAME' );
if ( ! preg_match( '/^[A-Za-z0-9_]{1,64}$/', $name ) ) {
	reply( array( 'ok' => false, 'error' => wpcenter_t( 'Nome da base de dados inválido.', 'Invalid database name.' ) ) );
}

mysqli_report( MYSQLI_REPORT_OFF );

// Servidor local gerido pelo WP Center: entra como root pelo socket e cria a base de dados e o utilizador do site.
$root_socket = (string) getenv( 'DB_ROOT_SOCKET' );
if ( '' !== $root_socket ) {
	$user = (string) getenv( 'DB_USER' );
	if ( ! preg_match( '/^[A-Za-z0-9_]{1,32}$/', $user ) ) {
		reply( array( 'ok' => false, 'error' => wpcenter_t( 'Utilizador inválido.', 'Invalid username.' ) ) );
	}
	$root = mysqli_init();
	if ( ! @mysqli_real_connect( $root, 'localhost', 'root', '', '', 0, $root_socket ) ) {
		reply( array( 'ok' => false, 'error' => wpcenter_t( 'Não foi possível aceder ao servidor local: ', 'Could not reach the local server: ' ) . mysqli_connect_error() ) );
	}
	$user_existed = $root->query( "SELECT 1 FROM mysql.user WHERE User = '$user'" )->num_rows > 0;
	$pass         = $root->real_escape_string( (string) getenv( 'DB_PASSWORD' ) );
	$sql  = array( "CREATE DATABASE IF NOT EXISTS `$name` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" );
	foreach ( array( 'localhost', '127.0.0.1' ) as $host ) {
		$sql[] = "CREATE USER IF NOT EXISTS '$user'@'$host' IDENTIFIED BY '$pass'";
		$sql[] = "GRANT ALL PRIVILEGES ON `$name`.* TO '$user'@'$host'";
	}
	foreach ( $sql as $query ) {
		if ( ! $root->query( $query ) ) {
			reply( array( 'ok' => false, 'error' => wpcenter_t( 'Erro ao preparar a base de dados: ', 'Error setting up the database: ' ) . $root->error ) );
		}
	}
}

$db = mysqli_init();
mysqli_options( $db, MYSQLI_OPT_CONNECT_TIMEOUT, 5 );
if ( ! @mysqli_real_connect( $db, getenv( 'DB_HOST' ), getenv( 'DB_USER' ), getenv( 'DB_PASSWORD' ), '', (int) getenv( 'DB_PORT' ) ) ) {
	if ( ! empty( $user_existed ) && 1045 === mysqli_connect_errno() ) {
		reply( array( 'ok' => false, 'error' => sprintf( wpcenter_t( 'O utilizador "%s" já existe noutro site com outra palavra-passe. Use a mesma palavra-passe ou outro utilizador.', 'The user "%s" already exists for another site with a different password. Use the same password or another user.' ), $user ) ) );
	}
	reply( array( 'ok' => false, 'error' => wpcenter_t( 'Não foi possível ligar: ', 'Could not connect: ' ) . mysqli_connect_error() ) );
}

// VERSION() devolve p.ex. "8.4.3" (MySQL) ou "11.4.2-MariaDB-log" (MariaDB).
$full    = (string) $db->query( 'SELECT VERSION()' )->fetch_row()[0];
$engine  = false !== stripos( $full, 'mariadb' ) ? 'mariadb' : 'mysql';
$version = preg_match( '/^(\d+\.\d+)/', $full, $m ) ? $m[1] : $full;

$escaped = $db->real_escape_string( $name );
$exists  = $db->query( "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$escaped'" )->num_rows > 0;

if ( ! $exists && '1' === getenv( 'DB_CREATE' )
	&& ! $db->query( "CREATE DATABASE `$name` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" ) ) {
	reply( array( 'ok' => false, 'error' => sprintf( wpcenter_t( 'Não foi possível criar a base de dados "%1$s": %2$s (no cPanel crie-a primeiro em "Bases de dados MySQL").', 'Could not create the database "%1$s": %2$s (on cPanel, create it first under "MySQL Databases").' ), $name, $db->error ) ) );
}

$tables = $db->query( "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$escaped' AND TABLE_NAME LIKE 'wp\\_%'" )->fetch_row()[0];

reply( array( 'ok' => true, 'engine' => $engine, 'version' => $version, 'tables' => (int) $tables ) );
