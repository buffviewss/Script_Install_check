#!/usr/bin/env bash
set -euo pipefail

PATTERN="${MAC_PATTERN:-^mac-sonoma-}"
SSH_USER="${SSH_USER:-}"

line(){ printf '%*s\n' "${COLUMNS:-110}" '' | tr ' ' '='; }
subline(){ printf '%*s\n' "${COLUMNS:-110}" '' | tr ' ' '-'; }
cores(){ awk -v x="$1" 'BEGIN{gsub("%","",x); printf "%.2f", x/100}'; }
rss_gib(){ awk -v kb="$1" 'BEGIN{printf "%.2f", kb/1024/1024}'; }

detect_mode() {
  os="$(uname -s)"
  if [[ "$os" == "Darwin" ]]; then
    echo "macos_guest"
  elif [[ "$os" == "Linux" ]] && command -v docker >/dev/null 2>&1; then
    echo "ubuntu_host"
  elif [[ "$os" == "Linux" ]]; then
    echo "linux_no_docker"
  else
    echo "unknown"
  fi
}

check_macos_guest() {
  line
  echo "macOS VM / GUEST CHECK"
  echo "Time: $(date)"
  line
  echo

  echo "===== HARDWARE ====="
  system_profiler SPHardwareDataType 2>/dev/null \
    | grep -E "Model Name|Model Identifier|Processor|Number of Processors|Total Number of Cores|Memory|Serial Number|Hardware UUID" || true

  echo
  echo "===== PLATFORM / SMBIOS ====="
  ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null \
    | egrep 'model|board-id|IOPlatformSerialNumber|IOPlatformUUID' || true

  echo
  echo "===== NETWORK EN0 ====="
  networksetup -listallhardwareports 2>/dev/null \
    | awk '/Hardware Port:|Device:|Ethernet Address:/' || true
  ifconfig en0 2>/dev/null | grep ether || true

  echo
  echo "===== EN0 BUILT-IN ====="
  ioreg -p IOService -l -w0 2>/dev/null \
    | grep -A25 -B25 '"IOInterfaceName" = "en0"' \
    | egrep 'IOBuiltin|IOMACAddress|IOInterfaceUnit|IOInterfaceName|IOInterfaceNamePrefix' || true

  echo
  echo "===== DISK ====="
  system_profiler SPSerialATADataType 2>/dev/null \
    | grep -E "APPLE SSD|Model|Serial Number|Medium Type|BSD Name|TRIM" || true
  diskutil list 2>/dev/null | head -80 || true

  echo
  echo "===== DISPLAY / DPR NOTE ====="
  system_profiler SPDisplaysDataType 2>/dev/null \
    | grep -E "Chipset Model|Type|Resolution|Displays|VRAM|Metal" || true
  echo "Safari DPR cần check trong Safari Console: window.devicePixelRatio"

  echo
  echo "===== AUDIO ====="
  system_profiler SPAudioDataType 2>/dev/null | head -80 || true
  echo
  echo "Test audio output:"
  afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 \
    && echo "Audio playback: PASS" \
    || echo "Audio playback: FAIL"

  echo
  echo "===== HYPERVISOR ====="
  sysctl kern.hv_vmm_present 2>/dev/null || true
  echo -n "VMM flag: "
  sysctl -n machdep.cpu.features 2>/dev/null | tr ' ' '\n' | grep -E '^VMM$' >/dev/null \
    && echo "PRESENT" \
    || echo "NOT FOUND"

  echo
  echo "===== CPU BASIC ====="
  sysctl -n machdep.cpu.brand_string 2>/dev/null || true
  sysctl -n machdep.cpu.vendor 2>/dev/null || true
  sysctl -n machdep.cpu.core_count 2>/dev/null || true
  sysctl -n machdep.cpu.thread_count 2>/dev/null || true

  echo
  line
  echo "GUEST QUICK READ"
  line
  echo "- Serial/UUID xem ở HARDWARE và PLATFORM."
  echo "- en0 phải là Ethernet chính, MAC đúng, built-in nếu có IOBuiltin."
  echo "- Audio playback PASS nếu afplay không lỗi."
  echo "- kern.hv_vmm_present=1 hoặc VMM PRESENT nghĩa là macOS vẫn thấy VM."
  echo "DONE"
}

check_ubuntu_host() {
  line
  echo "UBUNTU HOST / DOCKER-OSX CHECK"
  echo "Time: $(date)"
  echo "Pattern: $PATTERN"
  line
  echo

  echo "===== HOST SUMMARY ====="
  lscpu | grep -E 'Model name|CPU\(s\):|On-line CPU|Thread|Core|Socket|NUMA node' || true
  echo
  free -h
  uptime
  df -h /
  echo

  containers="$(docker ps --format '{{.Names}}' | grep -E "$PATTERN" | sort || true)"

  if [[ -z "$containers" ]]; then
    echo "Không tìm thấy container khớp pattern: $PATTERN"
    exit 0
  fi

  line
  echo "SUMMARY TABLE"
  line
  printf "%-18s %-9s %-8s %-10s %-18s %-12s %-18s %-18s\n" \
    "NAME" "CPU%" "CORES" "RAM" "IP" "SSH_PORT" "QEMU_MAC" "CPUSET"
  subline

  tmp="$(mktemp)"
  : > "$tmp"

  total_cpu="0"
  total_ram="0"

  for c in $containers; do
    stats="$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' "$c")"
    cpu="$(echo "$stats" | cut -d'|' -f1)"
    mem="$(echo "$stats" | cut -d'|' -f2 | awk -F' / ' '{print $1}')"

    mem_gib="$(echo "$mem" | awk '
      function to_gib(v,u) {
        if (u=="GiB") return v;
        if (u=="MiB") return v/1024;
        if (u=="KiB") return v/1024/1024;
        if (u=="GB") return v*1000/1024;
        if (u=="MB") return v/1024;
        return v;
      }
      {
        val=$0; unit=$0;
        gsub(/[A-Za-z]+/,"",val);
        gsub(/[0-9.]/,"",unit);
        printf "%.2f", to_gib(val,unit);
      }'
    )"

    total_cpu="$(awk -v a="$total_cpu" -v b="${cpu%\%}" 'BEGIN{print a+b}')"
    total_ram="$(awk -v a="$total_ram" -v b="$mem_gib" 'BEGIN{print a+b}')"

    ip="$(docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}' 2>/dev/null || true)"
    port="$(docker port "$c" 10022 2>/dev/null | awk -F: '{print $NF}' || true)"
    cpuset="$(docker inspect "$c" --format '{{.HostConfig.CpusetCpus}}' 2>/dev/null || true)"
    [[ -z "$cpuset" ]] && cpuset="all"

    qemu_line="$(docker top "$c" -eo pid,ppid,pcpu,pmem,rss,vsz,etime,args 2>/dev/null | grep qemu-system-x86_64 | head -1 || true)"
    qemu_mac="$(echo "$qemu_line" | grep -oE 'mac=[A-Fa-f0-9:]+' | head -1 | cut -d= -f2 || true)"
    [[ -z "$qemu_mac" ]] && qemu_mac="N/A"

    printf "%-18s %-9s %-8s %-10s %-18s %-12s %-18s %-18s\n" \
      "$c" "$cpu" "$(cores "$cpu")" "$mem" "${ip:-N/A}" "${port:-N/A}" "$qemu_mac" "$cpuset"

    envs="$(docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)"
    for key in SERIAL BOARD_SERIAL UUID MAC_ADDRESS DEVICE_MODEL; do
      val="$(echo "$envs" | grep -E "^${key}=" | head -1 | cut -d= -f2- || true)"
      echo "$c|$key|${val:-EMPTY}" >> "$tmp"
    done
    echo "$c|QEMU_MAC|${qemu_mac:-EMPTY}" >> "$tmp"
  done

  subline
  printf "TOTAL CPU: %.2f%% ≈ %.2f logical cores\n" "$total_cpu" "$(awk -v x="$total_cpu" 'BEGIN{print x/100}')"
  printf "TOTAL RAM: %.2f GiB\n" "$total_ram"

  echo
  line
  echo "DETAILED PER MAC"
  line

  for c in $containers; do
    echo
    subline
    echo "$c"
    subline

    echo "[Docker ENV identity]"
    docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
      | grep -E 'GENERATE|DEVICE_MODEL=|SERIAL=|BOARD_SERIAL=|UUID=|MAC_ADDRESS=|WIDTH=|HEIGHT=|CPU=|SMP=|CORES=|RAM=|CPUID_FLAGS=' \
      || echo "No identity ENV found"

    echo
    echo "[Network / port]"
    docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}Network={{$k}} IP={{$v.IPAddress}} Gateway={{$v.Gateway}}{{end}}' 2>/dev/null || true
    docker port "$c" 10022 2>/dev/null || echo "No SSH port mapping"

    echo
    echo "[QEMU runtime]"
    qemu_line="$(docker top "$c" -eo pid,ppid,pcpu,pmem,rss,vsz,etime,args 2>/dev/null | grep qemu-system-x86_64 | head -1 || true)"
    if [[ -z "$qemu_line" ]]; then
      echo "No QEMU process found"
    else
      qpid="$(echo "$qemu_line" | awk '{print $1}')"
      qcpu="$(echo "$qemu_line" | awk '{print $3}')"
      qrss="$(echo "$qemu_line" | awk '{print $5}')"

      echo "QEMU PID       : $qpid"
      echo "QEMU CPU       : ${qcpu}% ≈ $(cores "${qcpu}%") logical cores"
      echo "QEMU RSS       : $(rss_gib "$qrss") GiB"
      taskset -pc "$qpid" 2>/dev/null || true

      args="$(ps -p "$qpid" -o args= 2>/dev/null || true)"
      echo "QEMU CPU args  : $(echo "$args" | grep -oE -- '-cpu [^ ]+|-smp [^ ]+|-m [^ ]+|-name [^ ]+' | tr '\n' ' ')"
      echo "QEMU MAC       : $(echo "$args" | grep -oE 'mac=[A-Fa-f0-9:]+' | head -1 || echo N/A)"
      echo "Audio args     : $(echo "$args" | grep -oE 'audiodev|alsa|ich9-intel-hda|hda-duplex|hda-micro' | sort -u | tr '\n' ' ')"
      echo "Old flags      : $(echo "$args" | grep -oE 'vmware-cpuid-freq=on' || echo none)"
      echo "Disk flags     : $(echo "$args" | grep -oE 'APPLE SSD AP0512M|drive=MacHDD|BaseSystem.img|InstallMedia' | sort -u | tr '\n' ' ')"
    fi

    echo
    echo "[Volume /image]"
    vol="$(docker inspect "$c" --format '{{range .Mounts}}{{if eq .Destination "/image"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)"
    if [[ -n "$vol" ]]; then
      mp="$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)"
      echo "Volume     : $vol"
      echo "Mountpoint : $mp"
      [[ -n "$mp" ]] && sudo du -sh "$mp" 2>/dev/null || true
    else
      echo "No /image volume found"
    fi

    if [[ -n "$SSH_USER" ]]; then
      ssh_port="$(docker port "$c" 10022 2>/dev/null | awk -F: '{print $NF}' || true)"
      if [[ -n "$ssh_port" ]]; then
        echo
        echo "[macOS guest via SSH]"
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p "$ssh_port" "$SSH_USER@localhost" '
          system_profiler SPHardwareDataType | grep -E "Model Identifier|Serial Number|Hardware UUID|Total Number of Cores|Memory" || true
          ioreg -rd1 -c IOPlatformExpertDevice | egrep "model|board-id|IOPlatformSerialNumber|IOPlatformUUID" || true
          ifconfig en0 | grep ether || true
          sysctl kern.hv_vmm_present 2>/dev/null || true
        ' || echo "SSH failed"
      fi
    fi
  done

  echo
  line
  echo "DUPLICATE CHECK"
  line

  for key in DEVICE_MODEL SERIAL BOARD_SERIAL UUID MAC_ADDRESS QEMU_MAC; do
    echo
    echo "$key:"
    awk -F'|' -v k="$key" '$2==k && $3!="" {print $3}' "$tmp" \
      | sort | uniq -c | sort -nr \
      | awk '{if ($1>1) print "  DUPLICATE x"$1": "$2; else print "  unique x"$1": "$2}'
  done

  rm -f "$tmp"

  echo
  line
  echo "HOST QUICK READ"
  line
  echo "- CPU 100% ≈ 1 logical CPU."
  echo "- QEMU RSS = RAM thật VM đang giữ."
  echo "- Cpuset=all hoặc affinity 0-55 = chưa chia CPU NUMA pool."
  echo "- vmware-cpuid-freq=on = còn flag cũ."
  echo "- QEMU_MAC trùng = MAC runtime của card mạng macOS đang trùng."
  echo "- SERIAL/UUID EMPTY = container không set bằng GENERATE_SPECIFIC; muốn đọc thật thì dùng SSH_USER."
  echo "DONE"
}

mode="${FORCE_MODE:-$(detect_mode)}"

case "$mode" in
  ubuntu_host)
    check_ubuntu_host
    ;;
  macos_guest)
    check_macos_guest
    ;;
  linux_no_docker)
    echo "Đang chạy Linux nhưng không thấy docker. Đây không giống Ubuntu host Docker-OSX."
    ;;
  *)
    echo "Không nhận diện được môi trường: $(uname -s)"
    ;;
esac
