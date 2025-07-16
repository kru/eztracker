import sublime
import sublime_plugin
import os
import time
import subprocess
import json
import re
import shutil

# constants
EXIT_CODE_CONFIG_PARSE_ERROR = 103
EXIT_CODE_API_KEY_ERROR = 104
VERSION = "0.0.1"
CONFIG_FILE = os.path.expanduser("~/.eztracker.cfg")
PLUGIN_NAME = "eztracker-sublime"

class EztrackerConfig:
	def __init__(self):
		self.api_key = ""
		self.server_url = "http://localhost:8080"
		self.debug = True
		self.heartbeat_frequency = 2 # minutes
		self.cli_path = "eztracker_cli"
		self.send_buffer_seconds = 30
		self.ignore_patterns = [
            r"COMMIT_EDITMSG$",
            r"PULLREQ_EDITMSG$",
            r"MERGE_MSG$",
            r"TAG_EDITMSG$",
		]

	def load(self):
		# Load from config file
		try:
			with open(CONFIG_FILE, "r") as f:
				lines = f.readlines()
				print(lines)
				for line in lines:
					line = line.strip()
					if not line or line.startswith(("#", ";")):
						continue
					if line.startswith("[") and line.endswith("]"):
						current_section = line.strip("[]")
						continue
					if current_section == "settings":
						parts = line.split("=", 1)
						if len(parts) != 2:
							continue
						key, value = parts[0].strip(), parts[1].strip()
						if key == "api_key":
							self.api_key = value
						elif key == "server_url":
							self.server_url = value
						elif key == "debug":
							self.debug = value.lower() == "true"
						elif key == "heartbeat_frequency":
							try:
								self.heartbeat_frequency = float(value)
							except ValueError:
								pass
		except FileNotFoundError:
			if self.debug:
				print("[Eztracker] file not found error")
			pass
		except Exception as e:
			if self.debug:
				print(f"[Eztracker] Error loading config: {e}")

		log_debug("LOG API KEY {self.api_key}")
		if not self.api_key:
			sublime.message_dialog(
				"[Eztracker] API key not found. Set API_KEY env var or add to ~/.eztracker.cfg"
				)
			return False
		return True

class EztrackerState:
	def __init__(self):
		self.initialized = False
		self.config = EztrackerConfig()
		self.last_heartbeat = {} # {"file": {"last_activity_at:": 0, "last_heartbeat_at": 0}}
		self.heartbeat_buffer = []
		self.last_sent = time.time()

	def get_last_heartbeat(self, file):
		return self.last_heartbeat.get(file, {"last_activity_at:": 0, "last_heartbeat_at": 0})

	def set_last_heartbeat(self, file, last_activity_at, last_heartbeat_at):
		self.last_heartbeat[file] = {
			"last_activity_at": last_activity_at,
			"last_heartbeat_at": last_heartbeat_at
		}
		print(f"set_last_heartbeat {self.last_heartbeat}")

state = EztrackerState()

def log_debug(message):
	if state.config.debug:
		print(f"[Eztracker] {message}")

def is_ignored_file(file):
	if not file:
		return True
	for pattern in state.config.ignore_patterns:
		if re.search(pattern, file):
			return True
	return file.startswith("term:") or "MiniBufExplorer" in file or file == "--NO NAME--"

def get_file_language(view):
    # Get the scope name at the start of the buffer
    if view:
        scope = view.scope_name(0).strip()
        if scope:
            # Split scope string and look for 'source.<language>'
            scopes = scope.split()
            for s in scopes:
                if s.startswith("source."):
                    return s[7:]  # Remove "source." prefix, e.g., "source.python" → "python"
    
    # Fallback: Use file extension if available
    file_name = view.file_name()
    if file_name:
        extension = os.path.splitext(file_name)[1].lower()
        # Map common extensions to languages
        extension_map = {
            ".py": "python",
            ".go": "go",
            ".js": "javascript",
            ".ts": "typescript",
            ".java": "java",
            ".cpp": "cpp",
            ".c": "c",
            ".cs": "csharp",
            ".rb": "ruby",
            ".php": "php",
            ".html": "html",
            ".css": "css",
            ".json": "json",
            ".md": "markdown",
            ".odin": "odin",
        }
        return extension_map.get(extension, "")
    
    return ""  # Return empty string if no language can be determined

def append_heartbeat(view, is_write):
	file = view.file_name()
	if not file or is_ignored_file(file):
		log_debug("Ignoring file: {file}")
		return

	now = time.time()
	last = state.get_last_heartbeat(file)
	print(f"153 {last}")
	enough_time_passed = (now - last["last_heartbeat_at"]) > (
		state.config.heartbeat_frequency * 60
	)
	if state.debug
		print(f"is_write {is_write} enough_time_passed {enough_time_passed} {file} file not in {file not in state.last_heartbeat}")
	if is_write or enough_time_passed or file not in state.last_heartbeat:
		print(f"last {last}")
		duration = now - last["last_heartbeat_at"] if file in state.last_heartbeat else 0
		heartbeat = {
			"entity": file,
			"time": str(now),
			"is_write": is_write,
			"duration": duration,
			"language": get_file_language(view)
		}
		state.heartbeat_buffer.append(heartbeat)
		state.set_last_heartbeat(file, now, now)
		print(f"Append heartbeat for {file} (write: {is_write}, duration: {duration})")
		
	# Check if it's time to send buffered heartbeats
	if not isinstance(state.last_sent, (int, float)):
		state.last_sent = time.time()
	if now - state.last_sent > state.config.send_buffer_seconds and state.heartbeat_buffer:
		send_heartbeats()

def send_heartbeats():
	if not state.heartbeat_buffer:
		state.last_sent = time.time()
		return

	if not os.path.isfile(state.config.cli_path) and not shutil.which(state.config.cli_path):
		state.heartbeat_buffer = []
		return

	# Take the first heartbeat for main args
	heartbeat = state.heartbeat_buffer.pop(0)
	extra_heartbeats = state.heartbeat_buffer
	state.heartbeat_buffer = []

	if heartbeat["duration"] == 0:
		log_debug("Duration is 0, not sending heartbeat")
		return

	cmd = [
		state.config.cli_path,
		"--entity", heartbeat["entity"],
		"--time", heartbeat["time"],
		"--plugin", "{PLUGIN_NAME}/{VERSION}"
	]

	if heartbeat["duration"] != 0:
		cmd.extend(["--duration", str(heartbeat["duration"])])
	if heartbeat["is_write"]:
		cmd.append("--write")
	if heartbeat["language"]:
		cmd.extend(["--language" if heartbeat["language"].lower() == "forth" else
			"--alternate-language", heartbeat["language"]])
	if extra_heartbeats:
		cmd.extend(["--extra-heartbeats", json.dumps([{
			"entity": hb["entity"],
			"timestamp": float(hb["time"]),
			"is_write": hb["is_write"],
			"duration": hb["duration"],
			"language" if hb["language"].lower() == "forth" else 
				"alternate_language": hb["language"]
		} for hb in extra_heartbeats])])

	log_debug("Sending heartbeat: {' .join(cmd)'}" )
	try:
		result = subprocess.run(cmd, capture_output=True, text=True)
		if result.returncode == EXIT_CODE_API_KEY_ERROR:
			sublime.message_dialog("[Eztracker] Invalid API Key. Update in ~/.eztracker.cfg")
			state.initialized = False
		elif result.returncode == EXIT_CODE_CONFIG_PARSE_ERROR:
			sublime.message_dialog(
				"[Eztracker] CLI error (code {result.returncode}): {result.stderr}"
			)
		elif state.config.debug:
			log_debug("CLI output: {result.stdout}")
	except FileNotFoundError:
		sublime.message_dialog("[Eztracker] CLI not found: {state.config.cli_path}")
	except Exception as e:
		sublime.message_dialog("[Eztracker] Error running CLI: {e}")

	state.last_sent = time.time()

class EztrackerListener(sublime_plugin.EventListener):
	def on_init(self, views):
		if not state.initialized:
			if state.config.load():
				state.initialized = True
				log_debug("Plugin initialized")
			for view in views:
				append_heartbeat(view, False)

	def on_load(self, view):
		if state.initialized:
			append_heartbeat(view, False)

	def on_activated(self, view):
		if state.initialized:
			append_heartbeat(view, False)

	def on_modified(self, view):
		if state.initialized:
			file = view.file_name()
			if file and not is_ignored_file(file):
				now = time.time()
				last = state.get_last_heartbeat(file)
				print(f"on_modified {last}")
				state.set_last_heartbeat(file, now, last["last_heartbeat_at"])

	def on_text_command(self, view, command_name, args):
		if state.initialized and command_name == "save":
			append_heartbeat(view, True)

class EztrackerDebugCommand(sublime_plugin.ApplicationCommand):
    def run(self, enable):
        try:
            config_dir = os.path.dirname(CONFIG_FILE)
            if not os.path.exists(config_dir):
                os.makedirs(config_dir, mode=0o700)
            with open(CONFIG_FILE, "a") as f:
                f.write("[settings]\ndebug={str(enable).lower()}\n")
            state.config.debug = enable
            sublime.message_dialog(
				"[Eztracker] Debug mode {'enabled' if enable else 'disabled'}."
            )
        except Exception as e:
            sublime.message_dialog("[Eztracker] Error setting debug mode: {e}")