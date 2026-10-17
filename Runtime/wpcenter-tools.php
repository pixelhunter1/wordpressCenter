<?php
/**
 * Ferramentas para agentes de IA, chamadas pelo `wpc`. Uso: wp eval-file wpcenter-tools.php
 * Lê tudo do ambiente:
 *   WPCENTER_ACTION   context (resumo do site para um agente começar a trabalhar) | flush (limpa as caches)
 *                     | health (atualizações já conhecidas pelo WordPress e modo debug, numa linha WPCENTER_RESULT)
 *                     | wpvivid-forget (tira da lista do WPvivid os backups de WPCENTER_IDS, já apagados pela app)
 *   WPCENTER_JSON     1 → context em JSON
 */

// Mensagens na língua da app (WPCENTER_LANG, posto pelo WP Center): en ou pt.
if ( ! function_exists( 'wpcenter_t' ) ) {
	function wpcenter_t( $pt, $en ) {
		return 'en' === getenv( 'WPCENTER_LANG' ) ? $en : $pt;
	}
}

require_once ABSPATH . 'wp-admin/includes/plugin.php';

function wpcenter_tools_context() {
	$plugins = array();
	foreach ( get_plugins() as $file => $data ) {
		if ( is_plugin_active( $file ) ) {
			$plugins[ '.' === dirname( $file ) ? basename( $file, '.php' ) : dirname( $file ) ] = $data['Version'];
		}
	}
	$theme = wp_get_theme();

	// Construtores de páginas: pelos plugins ativos ou pelo tema (Bricks e Divi são temas).
	$known    = array(
		'elementor'                   => 'Elementor',
		'breakdance'                  => 'Breakdance',
		'oxygen'                      => 'Oxygen',
		'bb-plugin'                   => 'Beaver Builder',
		'beaver-builder-lite-version' => 'Beaver Builder',
		'js_composer'                 => 'WPBakery',
		'divi-builder'                => 'Divi',
	);
	$builders = array_values( array_unique( array_intersect_key( $known, $plugins ) ) );
	foreach ( array( 'bricks' => 'Bricks', 'divi' => 'Divi' ) as $template => $name ) {
		if ( strtolower( $theme->get_template() ) === $template ) {
			$builders[] = $name;
		}
	}
	if ( wp_is_block_theme() ) {
		$builders[] = wpcenter_t( 'Editor de sites (tema de blocos)', 'Site Editor (block theme)' );
	}

	$content = array();
	foreach ( get_post_types( array( 'public' => true ), 'objects' ) as $type ) {
		$count = (int) ( wp_count_posts( $type->name )->publish ?? 0 );
		if ( $count > 0 || in_array( $type->name, array( 'post', 'page' ), true ) ) {
			$content[ $type->name ] = $count;
		}
	}

	$front   = 'page' === get_option( 'show_on_front' ) ? get_the_title( (int) get_option( 'page_on_front' ) ) : wpcenter_t( 'últimos artigos', 'latest posts' );
	$context = array(
		'site'         => get_bloginfo( 'name' ),
		'url'          => home_url(),
		'wordpress'    => get_bloginfo( 'version' ),
		'php'          => PHP_VERSION,
		'language'     => get_locale(),
		'permalinks'   => get_option( 'permalink_structure' ) ? get_option( 'permalink_structure' ) : wpcenter_t( 'simples (?p=123)', 'plain (?p=123)' ),
		'front_page'   => $front,
		'theme'        => $theme->get( 'Name' ) . ' ' . $theme->get( 'Version' ) . ( $theme->parent() ? ' (' . wpcenter_t( 'filho de', 'child of' ) . ' ' . $theme->parent()->get( 'Name' ) . ')' : '' ),
		'theme_dir'    => 'wp-content/themes/' . $theme->get_stylesheet(),
		'builders'     => $builders,
		'plugins'      => $plugins,
		'mu_plugins'   => array_keys( get_mu_plugins() ),
		'content'      => $content,
		'menus'        => wp_list_pluck( wp_get_nav_menus(), 'name' ),
		'users'        => (int) count_users()['total_users'],
		'table_prefix' => $GLOBALS['wpdb']->prefix,
	);
	if ( class_exists( 'WooCommerce' ) ) {
		$orders                 = function_exists( 'wc_get_orders' ) ? wc_get_orders( array( 'limit' => 1, 'paginate' => true, 'return' => 'ids' ) ) : null;
		$context['woocommerce'] = array(
			'version'  => WC()->version,
			'currency' => get_woocommerce_currency(),
			'products' => (int) ( wp_count_posts( 'product' )->publish ?? 0 ),
			'orders'   => $orders ? (int) $orders->total : 0,
		);
	}

	if ( '1' === getenv( 'WPCENTER_JSON' ) ) {
		echo wp_json_encode( $context, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE ) . "\n";
		return;
	}
	$list  = function ( $items ) {
		return $items ? implode( ', ', $items ) : '—';
	};
	$lines = array(
		'# ' . $context['site'] . ' — ' . $context['url'],
		'',
		'- WordPress ' . $context['wordpress'] . ', PHP ' . $context['php'] . ', ' . $context['language'],
		'- ' . wpcenter_t( 'Tema', 'Theme' ) . ': ' . $context['theme'] . ' — `' . $context['theme_dir'] . '`',
		'- ' . wpcenter_t( 'Construtor', 'Builder' ) . ': ' . $list( $builders ),
		'- ' . wpcenter_t( 'Página inicial', 'Front page' ) . ': ' . $context['front_page'],
		'- ' . wpcenter_t( 'Ligações permanentes', 'Permalinks' ) . ': ' . $context['permalinks'],
		'- Menus: ' . $list( $context['menus'] ),
		'- ' . wpcenter_t( 'Utilizadores', 'Users' ) . ': ' . $context['users'] . ' · ' . wpcenter_t( 'prefixo das tabelas', 'table prefix' ) . ': `' . $context['table_prefix'] . '`',
	);
	if ( isset( $context['woocommerce'] ) ) {
		$wc      = $context['woocommerce'];
		$lines[] = '- WooCommerce ' . $wc['version'] . ': ' . $wc['products'] . ' ' . wpcenter_t( 'produtos', 'products' ) . ', ' . $wc['orders'] . ' ' . wpcenter_t( 'encomendas', 'orders' ) . ', ' . $wc['currency'];
	}
	$lines[] = '';
	$lines[] = '## ' . wpcenter_t( 'Conteúdo publicado', 'Published content' );
	foreach ( $content as $type => $count ) {
		$lines[] = '- ' . $type . ': ' . $count;
	}
	$lines[] = '';
	$lines[] = '## ' . wpcenter_t( 'Plugins ativos', 'Active plugins' ) . ' (' . count( $plugins ) . ')';
	foreach ( $plugins as $slug => $version ) {
		$lines[] = '- ' . $slug . ' ' . $version;
	}
	if ( $context['mu_plugins'] ) {
		$lines[] = '';
		$lines[] = '## Must-use plugins';
		$lines[] = '- ' . implode( "\n- ", $context['mu_plugins'] );
	}
	echo implode( "\n", $lines ) . "\n";
}

/** Caches do WordPress, dos construtores e dos plugins de cache mais comuns, cada uma só se existir no site. */
function wpcenter_tools_flush() {
	$done = array( wpcenter_t( 'cache de objetos', 'object cache' ) );
	wp_cache_flush();

	// Pela API (e não por SQL com LIKE, que o SQLite trata de outra forma): só o que é mesmo transient.
	global $wpdb;
	foreach ( $wpdb->get_col( "SELECT option_name FROM {$wpdb->options} WHERE option_name LIKE '%transient%'" ) as $name ) {
		if ( 0 === strpos( $name, '_transient_timeout_' ) || 0 === strpos( $name, '_site_transient_timeout_' ) ) {
			continue;
		}
		if ( 0 === strpos( $name, '_transient_' ) ) {
			delete_transient( substr( $name, strlen( '_transient_' ) ) );
		} elseif ( 0 === strpos( $name, '_site_transient_' ) ) {
			delete_site_transient( substr( $name, strlen( '_site_transient_' ) ) );
		}
	}
	$done[] = 'transients';

	flush_rewrite_rules( false );
	$done[] = wpcenter_t( 'regras de ligações permanentes', 'rewrite rules' );

	if ( class_exists( '\Elementor\Plugin' ) && isset( \Elementor\Plugin::$instance->files_manager ) ) {
		\Elementor\Plugin::$instance->files_manager->clear_cache();
		$done[] = 'Elementor CSS';
	}
	if ( has_action( 'litespeed_purge_all' ) ) {
		do_action( 'litespeed_purge_all' );
		$done[] = 'LiteSpeed Cache';
	}
	if ( function_exists( 'rocket_clean_domain' ) ) {
		rocket_clean_domain();
		$done[] = 'WP Rocket';
	}
	if ( function_exists( 'w3tc_flush_all' ) ) {
		w3tc_flush_all();
		$done[] = 'W3 Total Cache';
	}
	if ( function_exists( 'wp_cache_clear_cache' ) ) {
		wp_cache_clear_cache();
		$done[] = 'WP Super Cache';
	}
	if ( class_exists( 'autoptimizeCache' ) ) {
		autoptimizeCache::clearall();
		$done[] = 'Autoptimize';
	}
	echo wpcenter_t( 'Caches limpas: ', 'Caches cleared: ' ) . implode( ', ', $done ) . "\n";
}

/** Só o que o WordPress já guardou da última verificação: não contacta a internet. */
function wpcenter_tools_health() {
	$core    = get_site_transient( 'update_core' );
	$plugins = get_site_transient( 'update_plugins' );
	$themes  = get_site_transient( 'update_themes' );

	$available = null;
	foreach ( isset( $core->updates ) ? (array) $core->updates : array() as $offer ) {
		if ( 'upgrade' === ( $offer->response ?? '' ) ) {
			$available = $offer->current;
			break;
		}
	}
	$plugin_names = array();
	$installed    = get_plugins();
	foreach ( array_keys( (array) ( $plugins->response ?? array() ) ) as $file ) {
		$plugin_names[] = $installed[ $file ]['Name'] ?? dirname( $file );
	}
	$theme_names = array();
	foreach ( array_keys( (array) ( $themes->response ?? array() ) ) as $slug ) {
		$theme         = wp_get_theme( $slug );
		$theme_names[] = $theme->exists() ? $theme->get( 'Name' ) : $slug;
	}
	echo 'WPCENTER_RESULT ' . wp_json_encode(
		array(
			'core'    => $available,
			'plugins' => $plugin_names,
			'themes'  => $theme_names,
			'checked' => isset( $plugins->last_checked ),
			'debug'   => defined( 'WP_DEBUG' ) && WP_DEBUG,
		)
	) . "\n";
}

/** Os ficheiros já foram para o Lixo pela app: sem isto o WPvivid continuava a mostrá-los na lista de backups. */
function wpcenter_tools_wpvivid_forget() {
	if ( class_exists( 'WPvivid_Backuplist' ) ) {
		foreach ( array_filter( explode( ',', (string) getenv( 'WPCENTER_IDS' ) ) ) as $id ) {
			WPvivid_Backuplist::delete_backup( $id );
		}
	}
	echo 'WPCENTER_RESULT ' . wp_json_encode( array( 'ok' => true ) ) . "\n";
}

switch ( getenv( 'WPCENTER_ACTION' ) ) {
	case 'health':
		wpcenter_tools_health();
		break;
	case 'wpvivid-forget':
		wpcenter_tools_wpvivid_forget();
		break;
	case 'context':
		wpcenter_tools_context();
		break;
	case 'flush':
		wpcenter_tools_flush();
		break;
	default:
		fwrite( STDERR, wpcenter_t( "Ação desconhecida.\n", "Unknown action.\n" ) );
		exit( 1 );
}
