project('singularity-backups', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-backups"', language: 'c')
subdir('po')

glib_dep = dependency('glib-2.0')
gio_dep = dependency('gio-2.0')
gio_unix_dep = dependency('gio-unix-2.0')
gee_dep = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')
posix_dep = meson.get_compiler('vala').find_library('posix')
secret_dep = dependency('libsecret-1')
sodium_dep = declare_dependency(dependencies: [meson.get_compiler('c').find_library('sodium')])

conf = configuration_data()
conf.set_quoted('DATADIR', get_option('prefix') / get_option('datadir'))
conf.set_quoted('SYSCONFDIR', get_option('prefix') / get_option('sysconfdir'))
conf.set_quoted('LOCALEDIR', get_option('prefix') / get_option('localedir'))
conf.set_quoted('HELPER', get_option('prefix') / get_option('libexecdir') / 'singularity-backups-system-helper')
conf.set_quoted('VERSION', meson.project_version())
configure_file(output: 'config.h', configuration: conf)
config_inc = include_directories('.')
config_vapi = files('src/common/config.vapi')

engine_deps = [glib_dep, gio_dep, gio_unix_dep, gee_dep, json_dep, posix_dep, sodium_dep]

engine_sources = files(
  'src/engine/types.vala',
  'src/engine/index.vala',
  'src/engine/references.vala',
  'src/engine/exclusions.vala',
  'src/engine/backend.vala',
  'src/engine/providers.vala',
  'src/engine/local_backend.vala',
  'src/engine/exec_backend.vala',
  'src/engine/restorer.vala',
  'src/engine/schedule.vala',
  'src/engine/retention.vala',
  'src/engine/xattrs.vala',
  'src/engine/sodium.vapi',
  'src/engine/sealing.vala',
  'src/engine/remote_store.vala',
  'src/engine/remote_backend.vala',
  'src/engine/plugins.vala',
)

engine_lib = static_library('singularity-backups-engine',
  engine_sources,
  pic: true,
  dependencies: engine_deps,
  vala_header: 'singularity-backups-engine.h',
  vala_vapi: 'singularity-backups-engine.vapi',
)
engine_dep = declare_dependency(
  link_with: engine_lib,
  dependencies: engine_deps,
  include_directories: include_directories('.'),
)

engine_test = executable('backups-engine-test',
  ['tests/engine_test.vala', 'tests/remote_test.vala'],
  dependencies: [engine_dep],
  vala_args: ['--vapidir', meson.current_build_dir()],
)

executable('backups-perf',
  ['tests/perf.vala'],
  dependencies: [engine_dep],
  build_by_default: false,
)


executable('singularity-backups-daemon',
  [
    'src/daemon/main.vala',
    'src/daemon/service.vala',
    'src/daemon/support.vala',
    'src/daemon/destinations.vala',
    'src/daemon/power.vala',
    config_vapi,
  ],
  dependencies: [engine_dep, secret_dep],
  include_directories: config_inc,
  install: true,
  install_dir: get_option('libexecdir'),
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
service_conf.set('libexecdir', get_option('prefix') / get_option('libexecdir'))
configure_file(
  input: 'data/dev.sinty.backups.Daemon.service.in',
  output: 'dev.sinty.backups.Daemon.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)
configure_file(
  input: 'data/dev.sinty.backups.daemon.desktop.in',
  output: 'dev.sinty.backups.daemon.desktop',
  configuration: service_conf,
  install: true,
  install_dir: get_option('sysconfdir') / 'xdg' / 'autostart'
)

install_data('data/dev.sinty.backups.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)
install_data('data/backups.conf',
  install_dir: get_option('datadir') / 'singularity'
)

gtk_dep = dependency('gtk4')
libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

executable('singularity-backups',
  [
    'src/app/main.vala',
    'src/app/window.vala',
    'src/app/model.vala',
    'src/app/style.vala',
    'src/app/setup_page.vala',
    'src/app/overview_page.vala',
    'src/app/exclusions_page.vala',
    'src/app/time_travel.vala',
    'src/app/timeline.vala',
    'src/app/snapshot_browser.vala',
    'src/app/quick_look.vala',
    'src/common/client.vala',
    config_vapi,
  ],
  dependencies: [engine_dep, gtk_dep, libsingularity_dep],
  include_directories: config_inc,
  install: true,
)

configure_file(
  input: 'data/dev.sinty.backups.service.in',
  output: 'dev.sinty.backups.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)
install_data('data/dev.sinty.backups.desktop',
  install_dir: get_option('datadir') / 'applications'
)
install_data('data/dev.sinty.backups.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)
install_data('data/dev.sinty.backups.browse.ini', 'data/dev.sinty.backups.versions.ini',
  install_dir: get_option('datadir') / 'singularity' / 'files-actions'
)
install_data('data/icons/dev.sinty.backups.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

shared_module('backups-status',
  files('plugin/backups_status.vala', 'src/common/client.vala'),
  dependencies: [engine_dep, gtk_dep, libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'backups-status'
)
install_data('plugin/backups-status.plugin',
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'backups-status'
)

executable('singularity-backups-cpak',
  ['src/plugins/cpak.vala'],
  dependencies: [glib_dep, gio_dep, gee_dep, json_dep],
  install: true,
  install_dir: get_option('libexecdir'),
)

executable('singularity-backups-cloud',
  ['src/plugins/cloud.vala'],
  dependencies: [glib_dep, gio_dep, gio_unix_dep, gee_dep, json_dep, libsingularity_dep],
  install: true,
  install_dir: get_option('libexecdir'),
)

plugin_conf = configuration_data()
plugin_conf.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
configure_file(
  input: 'data/sources/cpak.backup-source.in',
  output: 'cpak.backup-source',
  configuration: plugin_conf,
  install: true,
  install_dir: get_option('datadir') / 'singularity' / 'backups' / 'sources',
)
configure_file(
  input: 'data/destinations/cloud.backup-destination.in',
  output: 'cloud.backup-destination',
  configuration: plugin_conf,
  install: true,
  install_dir: get_option('datadir') / 'singularity' / 'backups' / 'destinations',
)

system_helper = executable('singularity-backups-system-helper',
  ['src/helper/main.vala'],
  dependencies: [glib_dep, gio_dep, posix_dep],
  install: true,
  install_dir: get_option('libexecdir'),
)
policy_conf = configuration_data()
policy_conf.set('LIBEXECDIR', get_option('prefix') / get_option('libexecdir'))
configure_file(
  input: 'data/dev.sinty.backups.policy.in',
  output: 'dev.sinty.backups.policy',
  configuration: policy_conf,
  install: true,
  install_dir: get_option('datadir') / 'polkit-1' / 'actions',
)

test('engine', engine_test,
  env: [
    'TEST_ADAPTER=' + meson.current_source_dir() / 'tests' / 'fake-adapter.py',
    'TEST_SYSTEM_HELPER=' + system_helper.full_path(),
    'TEST_DESTINATION=' + meson.current_source_dir() / 'tests' / 'fake-destination.py',
    'TEST_SOURCE=' + meson.current_source_dir() / 'tests' / 'fake-source.sh',
  ],
  depends: [system_helper],
  timeout: 300,
)
