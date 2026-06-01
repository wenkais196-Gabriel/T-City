import os
import re
import sys
import datetime

# Paths
script_dir = os.path.dirname(os.path.abspath(__file__))
progress_file_path = os.path.join(script_dir, "PROJECT_PROGRESS.md")
modules_dir = os.path.join(script_dir, "T-CityLite.base", "configs", "modules")

def load_progress():
    if not os.path.exists(progress_file_path):
        print(f"Error: Could not find PROJECT_PROGRESS.md at {progress_file_path}")
        sys.exit(1)
    with open(progress_file_path, "r", encoding="utf-8") as f:
        return f.read()

def save_progress(content):
    # Update timestamp
    current_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    content = re.sub(
        r"- \*\*最后更新时间\*\*: .*",
        f"- **最后更新时间**: {current_time}",
        content
    )
    with open(progress_file_path, "w", encoding="utf-8") as f:
        f.write(content)

def cmd_sync():
    if not os.path.exists(modules_dir):
        print(f"Error: Could not find modules directory at {modules_dir}")
        sys.exit(1)

    print(f"Scanning active resources in {modules_dir}...")
    cfg_files = [f for f in os.listdir(modules_dir) if f.endswith(".cfg")]
    cfg_files.sort()

    table_rows = []
    total_resources_count = 0

    for file_name in cfg_files:
        file_path = os.path.join(modules_dir, file_name)
        with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
        
        purpose = "Module configuration"
        if lines:
            first_line = lines[0].strip()
            if first_line.startswith("#"):
                purpose = first_line.lstrip("#").strip()
                
        active_resources = []
        for line in lines:
            match = re.match(r"^\s*(ensure|start)\s+(\S+)", line, re.IGNORECASE)
            if match:
                resource_name = match.group(2)
                resource_name = re.split(r"[\s#;]", resource_name)[0]
                active_resources.append(f"`{resource_name}`")
                
        count = len(active_resources)
        total_resources_count += count
        
        if count > 0:
            resource_list_str = ", ".join(active_resources)
            table_rows.append(f"| **{file_name}** | {purpose} | **{count}** | {resource_list_str} |")
        else:
            table_rows.append(f"| **{file_name}** | {purpose} | **0** | *No active resources* |")

    table_headers = [
        "| Module Cfg | Description | Active Count | Active Resources |",
        "| :--- | :--- | :--- | :--- |"
    ]
    table_content = "\n".join(table_headers + table_rows)

    progress_content = load_progress()
    start_marker = "<!-- ACTIVE_RESOURCES_START -->"
    end_marker = "<!-- ACTIVE_RESOURCES_END -->"

    pattern = re.compile(rf"{start_marker}.*?{end_marker}", re.DOTALL)
    replacement_string = f"{start_marker}\n\nActive resources detected in codebase (**{total_resources_count}** resources across **{len(cfg_files)}** modules):\n\n{table_content}\n\n{end_marker}"
    new_content = re.sub(pattern, replacement_string, progress_content)

    save_progress(new_content)
    print(f"Scanned {total_resources_count} resources across {len(cfg_files)} modules.")
    print("Codebase active resources successfully synchronized in PROJECT_PROGRESS.md!")

def cmd_view():
    content = load_progress()
    
    # Extract current stage and update time
    stage_match = re.search(r"- \*\*当前开发阶段\*\*: `(.*?)`", content)
    time_match = re.search(r"- \*\*最后更新时间\*\*: (.*)", content)
    
    print("=" * 60)
    print(" T-CITY LITE - CURRENT PROJECT DASHBOARD ")
    print("=" * 60)
    if stage_match:
        print(f"Active Milestone: {stage_match.group(1)}")
    if time_match:
        print(f"Last Synchronized: {time_match.group(1)}")
    print("-" * 60)
    
    # Extract Current Checklist
    checklist_match = re.search(r"## 🚧 当前阶段任务清单 (.*?)(?=\n---|\Z)", content, re.DOTALL)
    if checklist_match:
        print("Active Checklist Tasks:")
        lines = checklist_match.group(1).strip().split("\n")
        for line in lines:
            line_str = line.strip()
            if line_str.startswith("- ["):
                # Print nicely formatted task checkbox
                status_symbol = line_str[3]
                task_text = line_str[6:].strip()
                if status_symbol == "x":
                    print(f"  [x] Done:        {task_text}")
                elif status_symbol == "/":
                    print(f"  [/] In Progress: {task_text}")
                else:
                    print(f"  [ ] Pending:     {task_text}")
            elif line_str.startswith("###"):
                print(f"\n* {line_str.lstrip('#').strip()} *")
    else:
        print("No active checklist found.")
    print("=" * 60)

def cmd_mark_task(keyword, target_status):
    content = load_progress()
    
    # Find the current checklist section
    start_sec = "## 🚧 当前阶段任务清单"
    if start_sec not in content:
        print("Error: Could not find current checklist section in progress file.")
        sys.exit(1)
        
    lines = content.split("\n")
    found = False
    new_lines = []
    
    # We want to change [ ] or [/] or [x] to target_status on the matching line
    status_symbol = " "
    if target_status == "start":
        status_symbol = "/"
        status_text = "In Progress"
    elif target_status == "complete":
        status_symbol = "x"
        status_text = "Completed"
    else:
        status_symbol = " "
        status_text = "Pending"
        
    for line in lines:
        if line.strip().startswith("- [") and keyword.lower() in line.lower():
            # Match `- [ ] task text` or `- [/] task text` or `- [x] task text`
            updated_line = re.sub(r"^- \[[ x/]\]", f"- [{status_symbol}]", line)
            if updated_line != line:
                print(f"Task match found! Changing to [{status_symbol}] ({status_text}):")
                print(f"  Old: {line.strip()}")
                print(f"  New: {updated_line.strip()}")
                line = updated_line
                found = True
        new_lines.append(line)
        
    if not found:
        print(f"Error: No task containing '{keyword}' found in the active checklist.")
        sys.exit(1)
        
    save_progress("\n".join(new_lines))
    print("PROJECT_PROGRESS.md successfully updated!")

def print_usage():
    print("Usage:")
    print("  python manage_progress.py view              - Display current active progress checklist")
    print("  python manage_progress.py sync              - Scan configs/modules and update active resources table")
    print("  python manage_progress.py start \"<kw>\"     - Mark task containing <kw> as In Progress ( [/] )")
    print("  python manage_progress.py complete \"<kw>\"  - Mark task containing <kw> as Completed ( [x] )")
    print("  python manage_progress.py reset \"<kw>\"     - Mark task containing <kw> as Pending ( [ ] )")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print_usage()
        sys.exit(0)
        
    cmd = sys.argv[1].lower()
    
    if cmd == "view":
        cmd_view()
    elif cmd == "sync":
        cmd_sync()
    elif cmd in ["start", "complete", "reset"]:
        if len(sys.argv) < 3:
            print(f"Error: Missing keyword for '{cmd}' command.")
            print(f"Example: python manage_progress.py {cmd} \"AddScaledMoney\"")
            sys.exit(1)
        keyword = sys.argv[2]
        cmd_mark_task(keyword, cmd)
    else:
        print(f"Unknown command: {cmd}")
        print_usage()
        sys.exit(1)
