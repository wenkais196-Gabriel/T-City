# -*- coding: utf-8 -*-
import os
import sys
import re
from PIL import Image

# Initialize Windows virtual terminal sequences for ANSI colors
if os.name == 'nt':
    os.system('color')

# Color codes for pretty output
C_GREEN = '\033[92m'
C_YELLOW = '\033[93m'
C_BLUE = '\033[94m'
C_RED = '\033[91m'
C_CYAN = '\033[96m'
C_BOLD = '\033[1m'
C_RESET = '\033[0m'

def print_banner():
    print(f"{C_CYAN}{C_BOLD}==================================================")
    print("      GTA V / FiveM Map Texture Optimizer")
    print(f"=================================================={C_RESET}")

def main():
    print_banner()
    
    target_dir = None
    MAX_RESOLUTION = 1024
    
    # Check if arguments are provided via command line
    if len(sys.argv) > 1:
        # Retrieve target directory from arguments
        arg_path = sys.argv[1].strip()
        target_dir = os.path.abspath(arg_path.replace('\\', '/'))
        
        # Retrieve resolution limit from arguments if available
        if len(sys.argv) > 2 and sys.argv[2].isdigit():
            MAX_RESOLUTION = int(sys.argv[2])
            
        print(f"{C_GREEN}[+] 使用命令行参数定位目录: {target_dir}{C_RESET}")
        print(f"{C_BLUE}[i] 使用命令行参数分辨率限制: {MAX_RESOLUTION}x{MAX_RESOLUTION}{C_RESET}\n")
    else:
        # Interactive mode
        default_path = "D:/桌面/hospital_textures"
        print(f"请输入已导出的 openFormats 地图文件夹的绝对路径。")
        print(f"(例如: D:/桌面/dealer_textures 或 D:/桌面/prison_main_textures)")
        if os.path.exists(default_path):
            print(f"默认路径 [回车默认使用]: {default_path}")
            
        user_input = input("路径: ").strip()
        if not user_input:
            user_input = default_path
            
        target_dir = os.path.abspath(user_input.replace('\\', '/'))
        
        max_res_input = input("请输入贴图压缩最大分辨率限制 (默认 1024, 例如 1024 或 512): ").strip()
        if max_res_input.isdigit():
            MAX_RESOLUTION = int(max_res_input)
            
        print(f"{C_BLUE}[i] 开始处理！优化规格：最大分辨率为 {MAX_RESOLUTION}x{MAX_RESOLUTION}，尺寸将自动修约为偶数。{C_RESET}\n")
    
    # Validate directory
    if not os.path.exists(target_dir) or not os.path.isdir(target_dir):
        print(f"{C_RED}[X] 错误: 路径 '{target_dir}' 不存在或不是一个文件夹。{C_RESET}")
        sys.exit(1)

    total_subfolders = 0
    cleaned_dds_count = 0
    optimized_otx_count = 0
    resized_images_count = 0
    skipped_images_count = 0
    failed_count = 0

    # 3. Recursively walk through folders
    dirs_to_process = []
    for root, dirs, files in os.walk(target_dir):
        dirs_to_process.append(root)

    for current_dir in dirs_to_process:
        try:
            dir_files = os.listdir(current_dir)
        except Exception as e:
            print(f"  {C_RED}[!] 无法访问目录 {current_dir}: {e}{C_RESET}")
            continue
            
        has_assets = any(f.lower().endswith(('.otx', '.png', '.jpg', '.jpeg', '.dds')) for f in dir_files)
        if not has_assets:
            continue
            
        total_subfolders += 1
        folder_name = os.path.basename(current_dir) or current_dir
        print(f"{C_BOLD}[o] 正在处理目录: {folder_name}{C_RESET}")

        # A. Clean up .dds files
        for filename in dir_files:
            if filename.lower().endswith('.dds'):
                dds_path = os.path.join(current_dir, filename)
                try:
                    os.remove(dds_path)
                    cleaned_dds_count += 1
                except Exception as e:
                    print(f"  {C_RED}[!] 删除 DDS 失败 {filename}: {e}{C_RESET}")

        # Re-fetch files list after deleting DDS files
        try:
            dir_files = os.listdir(current_dir)
        except Exception:
            continue

        # B. Scan and optimize OTX descriptor files
        for filename in dir_files:
            if filename.lower().endswith('.otx'):
                otx_path = os.path.join(current_dir, filename)
                try:
                    with open(otx_path, 'r', encoding='utf-8', errors='ignore') as f:
                        content = f.read()
                    
                    updated = False
                    base_name = os.path.splitext(filename)[0]
                    
                    # Ensure references point to PNG instead of DDS
                    dds_pattern = re.compile(re.escape(base_name) + r'\.dds', re.IGNORECASE)
                    if dds_pattern.search(content):
                        content = dds_pattern.sub(f"{base_name}.png", content)
                        updated = True
                    
                    # Force Mipmaps (Level 1 -> Level 5)
                    levels_pattern = re.compile(r'Levels\s+1\b', re.IGNORECASE)
                    if levels_pattern.search(content):
                        content = levels_pattern.sub("Levels 5", content)
                        updated = True
                        print(f"   -> {C_YELLOW}[*] 强制开启 Mipmaps (Levels 1 -> 5): {filename}{C_RESET}")

                    if updated:
                        with open(otx_path, 'w', encoding='utf-8', newline='') as f:
                            f.write(content)
                        optimized_otx_count += 1
                except Exception as e:
                    print(f"  {C_RED}[!] 处理 OTX 失败 {filename}: {e}{C_RESET}")

        # C. Scan and resize PNG/JPG/JPEG files
        for filename in dir_files:
            if filename.lower().endswith(('.png', '.jpg', '.jpeg')):
                img_path = os.path.join(current_dir, filename)
                try:
                    with Image.open(img_path) as img:
                        width, height = img.size
                        
                        # Resizing logic if dimensions exceed limits
                        if width > MAX_RESOLUTION or height > MAX_RESOLUTION:
                            if width >= height:
                                new_width = MAX_RESOLUTION
                                new_height = int((height * MAX_RESOLUTION) / width)
                            else:
                                new_height = MAX_RESOLUTION
                                new_width = int((width * MAX_RESOLUTION) / height)
                            
                            # Ensure dimensions are even numbers (essential for GPU DXT block compression)
                            if new_width % 2 != 0: new_width -= 1
                            if new_height % 2 != 0: new_height -= 1
                            
                            # Protect against 0 width/height
                            new_width = max(2, new_width)
                            new_height = max(2, new_height)

                            resized_img = img.resize((new_width, new_height), Image.Resampling.LANCZOS)
                            
                            resized_img.save(img_path)
                            print(f"   [OK] {C_GREEN}已压缩贴图: {filename} ({width}x{height} -> {new_width}x{new_height}){C_RESET}")
                            resized_images_count += 1
                        else:
                            skipped_images_count += 1
                except Exception as e:
                    print(f"   {C_RED}[!] 压缩贴图失败 {filename}: {e}{C_RESET}")
                    failed_count += 1

    # 4. Final summary report
    print(f"\n{C_CYAN}{C_BOLD}==================================================")
    print("              贴图压缩与优化完成！")
    print(f"=================================================={C_RESET}")
    print(f"[*] 优化数据统计报告：")
    print(f"  - 目录: 处理模型目录 {C_GREEN}{total_subfolders}{C_RESET} 个")
    print(f"  - 清理: 清除冲突的 DDS 文件 {C_GREEN}{cleaned_dds_count}{C_RESET} 个")
    print(f"  - 描述: 优化 OTX 贴图描述符 {C_GREEN}{optimized_otx_count}{C_RESET} 个")
    print(f"  - 压缩: 降解析压缩大型贴图 {C_GREEN}{resized_images_count}{C_RESET} 张")
    print(f"  - 保留: 保留原本轻量级贴图 {C_GREEN}{skipped_images_count}{C_RESET} 张")
    if failed_count > 0:
        print(f"  - 失败: 处理失败文件总数 {C_RED}{failed_count}{C_RESET} 个")
    print(f"{C_CYAN}{C_BOLD}=================================================={C_RESET}")
    print(f"{C_YELLOW}--> 现在，您可以直接在 OpenIV 中将优化后的目录拖拽导入回 stream 中了！{C_RESET}\n")

if __name__ == '__main__':
    main()
