extends Control

const RELEASE_ROOT := "https://github.com/NicolasFerec/le-dernier-train-godot/releases/"
const GAME_DATA := "user://../Le Dernier Train"
const PREFERENCES := GAME_DATA + "/preferences.cfg"
const LEGACY_GAME_DATA := "user://../Arène coop"
const LEGACY_INSTALL_ROOT := "user://../Arène coop Launcher/versions"
const INSTALL_ROOT := "user://versions"
const DEV_INSTALL_ROOT := "user://dev-versions"

var platform := "windows-x86_64" if OS.get_name() == "Windows" else "linux-x86_64"
var extension := ".exe" if OS.get_name() == "Windows" else ".x86_64"
var executable := "Le-Dernier-Train" + extension
var legacy_executable := "Arene-coop" + extension
var version_pattern := RegEx.create_from_string("^(0|[1-9][0-9]{0,5})\\.(0|[1-9][0-9]{0,5})\\.(0|[1-9][0-9]{0,5})$")
var request := HTTPRequest.new()
var archive_path := ""
var use_dev := false
var preferences := ConfigFile.new()
var game_arguments := OS.get_cmdline_user_args()


func _ready() -> void:
	var preferences_path := PREFERENCES
	if not FileAccess.file_exists(preferences_path):
		preferences_path = LEGACY_GAME_DATA.path_join("preferences.cfg")
	preferences.load(preferences_path)
	TranslationServer.set_locale(preferences.get_value("interface", "language", "fr"))
	use_dev = preferences.get_value("updates", "channel", "latest") == "dev"
	add_child(request)
	request.use_threads = true
	$Retry.pressed.connect(_start)
	$ChooseChannel.pressed.connect(_save_channel)
	var open_options := game_arguments.has("--launcher-settings")
	if open_options:
		game_arguments.remove_at(game_arguments.find("--launcher-settings"))
	if open_options or not preferences.has_section_key("updates", "channel"):
		_show_channel_options()
	else:
		_start()


func _show_channel_options() -> void:
	$Progress.hide()
	$Status.text = ""
	$ChannelOptions/Channel.add_item(tr("SETTINGS_UPDATE_LATEST"))
	$ChannelOptions/Channel.add_item(tr("SETTINGS_UPDATE_DEV"))
	$ChannelOptions/Channel.select(1 if use_dev else 0)
	$ChannelOptions.show()
	$ChooseChannel.show()
	$ChannelOptions/Channel.grab_focus()


func _save_channel() -> void:
	use_dev = $ChannelOptions/Channel.selected == 1
	preferences.set_value("updates", "channel", "dev" if use_dev else "latest")
	if DirAccess.make_dir_recursive_absolute(GAME_DATA) != OK or preferences.save(PREFERENCES) != OK:
		$Status.text = tr("SETTINGS_SAVE_FAILED")
		return
	$ChannelOptions.hide()
	$ChooseChannel.hide()
	_start()


func _process(_delta: float) -> void:
	if not archive_path.is_empty():
		var total := request.get_body_size()
		if total > 0:
			$Progress.value = 100.0 * request.get_downloaded_bytes() / total


func _start() -> void:
	$Retry.hide()
	$Progress.show()
	$Progress.value = 0
	$Status.text = tr("UPDATER_CHECK")
	var installed := _installed_versions(use_dev)
	if not await _update(installed, use_dev):
		if use_dev and installed.is_empty():
			$Status.text = tr("UPDATER_DEV_FALLBACK")
			await get_tree().create_timer(1.4).timeout
			installed = _installed_versions(false)
			if await _update(installed, false) or not installed.is_empty():
				_launch(_installed_versions(false), false)
				return
		$Status.text = tr("UPDATER_FIRST_FAILED" if installed.is_empty() else "UPDATER_OFFLINE")
		if installed.is_empty():
			$Retry.show()
			return
		await get_tree().create_timer(1.4).timeout
	_launch(_installed_versions(use_dev), use_dev)


func _update(installed: Array[String], dev: bool) -> bool:
	request.timeout = 7
	request.body_size_limit = 16384
	var manifest_path := "download/dev/update.json" if dev else "latest/download/update.json"
	if request.request(RELEASE_ROOT + manifest_path) != OK:
		return false
	var response: Array = await request.request_completed
	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		return false
	var manifest = JSON.parse_string(response[3].get_string_from_utf8())
	if not manifest is Dictionary:
		return false
	var version = manifest.get("version")
	if not version is String or version_pattern.search(version) == null:
		return false
	if not installed.is_empty() and not _newer(version, installed[0]):
		return true
	var legacy_package := not (manifest as Dictionary).has("packages_sha256")
	if dev and legacy_package:
		return false
	var checksums = manifest.get("sha256" if legacy_package else "packages_sha256")
	if not checksums is Dictionary:
		return false
	var checksum = checksums.get(platform)
	if not checksum is String or checksum.length() != 64 or not checksum.is_valid_hex_number(false):
		return false

	# A separate staging directory keeps interrupted downloads away from the installed game.
	var root := DEV_INSTALL_ROOT if dev else INSTALL_ROOT
	var staging := root.path_join(version + "-" + str(OS.get_process_id()) + ".tmp")
	if DirAccess.make_dir_recursive_absolute(staging) != OK:
		return false
	var downloaded := await _download(version, staging, checksum, legacy_package, dev)
	if not downloaded:
		return false
	$Status.text = tr("UPDATER_INSTALL") % version
	await RenderingServer.frame_post_draw
	var installed_ok := _unpack(staging, legacy_package)
	DirAccess.remove_absolute(staging.path_join("game.zip"))
	return installed_ok and DirAccess.rename_absolute(staging, root.path_join(version)) == OK


func _download(version: String, staging: String, checksum: String, legacy_package: bool, dev: bool) -> bool:
	$Status.text = tr("UPDATER_DOWNLOAD") % version
	archive_path = staging.path_join("game.zip")
	request.timeout = 120
	request.body_size_limit = 200 * 1024 * 1024
	request.download_file = archive_path
	var prefix := "Arene-coop-" if legacy_package else "Le-Dernier-Train-"
	var tag := "dev" if dev else "v" + version
	var suffix := "-" + version if dev else ""
	var started := request.request(RELEASE_ROOT + "download/" + tag + "/" + prefix + platform + suffix + ".zip")
	var ok := false
	if started == OK:
		var response: Array = await request.request_completed
		ok = response[0] == HTTPRequest.RESULT_SUCCESS and response[1] == 200
	ok = ok and FileAccess.get_sha256(archive_path) == checksum
	if not ok:
		DirAccess.remove_absolute(archive_path)
	archive_path = ""
	request.download_file = ""
	return ok


func _unpack(staging: String, legacy_package: bool) -> bool:
	var archived_executable := legacy_executable if legacy_package else executable
	var allowed := [archived_executable, "GODOT-LICENSE.txt", "GODOT-COPYRIGHT.txt", "GODOTSTEAM-LICENSE.md", "KENNEY-LICENSE.txt"]
	if OS.get_name() == "Windows":
		allowed.append_array(["steam_api64.dll", "libgodotsteam.windows.template_release.x86_64.dll"])
	else:
		allowed.append_array(["libsteam_api.so", "libgodotsteam.linux.template_release.x86_64.so"])
	var zip := ZIPReader.new()
	if zip.open(staging.path_join("game.zip")) != OK or zip.get_files().size() != allowed.size():
		return false
	for filename in allowed:
		if not zip.file_exists(filename):
			return false
		var output_name: String = executable if filename == archived_executable else filename
		var output := FileAccess.open(staging.path_join(output_name), FileAccess.WRITE)
		if output == null or not output.store_buffer(zip.read_file(filename)):
			return false
	zip.close()
	if OS.get_name() != "Windows":
		return FileAccess.set_unix_permissions(staging.path_join(executable), 493) == OK
	return true


func _installed_versions(dev: bool) -> Array[String]:
	var versions: Array[String] = []
	var roots := [DEV_INSTALL_ROOT] if dev else [INSTALL_ROOT, LEGACY_INSTALL_ROOT]
	for root: String in roots:
		if not DirAccess.dir_exists_absolute(root):
			continue
		for folder in DirAccess.get_directories_at(root):
			if version_pattern.search(folder) != null and not versions.has(folder) and _game_path(folder, dev) != "":
				versions.append(folder)
	versions.sort_custom(_newer)
	return versions


func _game_path(version: String, dev: bool) -> String:
	var root := DEV_INSTALL_ROOT if dev else INSTALL_ROOT
	var current := root.path_join(version).path_join(executable)
	if FileAccess.file_exists(current):
		return ProjectSettings.globalize_path(current)
	if dev:
		return ""
	var legacy := LEGACY_INSTALL_ROOT.path_join(version).path_join(legacy_executable)
	return ProjectSettings.globalize_path(legacy) if FileAccess.file_exists(legacy) else ""


func _newer(a: String, b: String) -> bool:
	var left := a.split(".")
	var right := b.split(".")
	for index in range(3):
		if left[index] != right[index]:
			return left[index].to_int() > right[index].to_int()
	return false


func _launch(versions: Array[String], dev: bool) -> void:
	$Status.text = tr("UPDATER_START")
	for version in versions:
		var path := _game_path(version, dev)
		if not path.is_empty() and OS.create_process(path, game_arguments) != -1:
			if OS.get_name() == "Linux" and OS.has_feature("template"):
				var error := _install_linux_menu_entry()
				if error != OK:
					push_warning("Could not install the Linux application menu entry: " + error_string(error))
			get_tree().quit()
			return
	$Status.text = tr("UPDATER_LAUNCH_FAILED")
	$Retry.show()


func _install_linux_menu_entry() -> Error:
	var data_home := OS.get_environment("XDG_DATA_HOME")
	if not data_home.is_absolute_path():
		data_home = OS.get_environment("HOME").path_join(".local/share")
	if not data_home.is_absolute_path():
		return ERR_UNCONFIGURED

	var applications := data_home.path_join("applications")
	var error := DirAccess.make_dir_recursive_absolute(applications)
	if error != OK:
		return error

	var launcher := ProjectSettings.globalize_path("user://le-dernier-train-launcher")
	var running := OS.get_executable_path()
	var temporary_suffix := ".tmp-" + str(OS.get_process_id())
	if running != launcher:
		var temporary_launcher := launcher + temporary_suffix
		error = DirAccess.copy_absolute(running, temporary_launcher)
		if error == OK:
			error = FileAccess.set_unix_permissions(temporary_launcher, 493)
		if error == OK:
			error = DirAccess.rename_absolute(temporary_launcher, launcher)
		if error != OK:
			DirAccess.remove_absolute(temporary_launcher)
			return error

	# Exec applies desktop string escaping before parsing the quoted command.
	var command := launcher.replace("\\", "\\\\").replace("\"", "\\\"")
	command = command.replace("$", "\\$").replace("`", "\\`").replace("%", "%%")
	command = command.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
	var entry := """[Desktop Entry]
Type=Application
Name=Le Dernier Train
Exec="%s"
Icon=applications-games
Categories=Game;
Terminal=false
""" % command
	var desktop_file := applications.path_join("io.github.NicolasFerec.LeDernierTrain.desktop")
	if FileAccess.get_file_as_string(desktop_file) == entry:
		return OK
	var temporary_entry := desktop_file + temporary_suffix
	var file := FileAccess.open(temporary_entry, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var written := file.store_string(entry)
	file.close()
	error = DirAccess.rename_absolute(temporary_entry, desktop_file) if written else ERR_FILE_CANT_WRITE
	if error != OK:
		DirAccess.remove_absolute(temporary_entry)
	return error
