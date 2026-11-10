package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"
)

const (
	defaultBind        = "0.0.0.0"
	defaultTCPPort     = 19090
	defaultUDPPort     = 19091
	defaultMode        = "reflector"
	defaultControlAddr = "127.0.0.1:8443"
)

// errHelp is returned when the user asks for -h. It is not a failure.
var errHelp = errors.New("help")

// Config is the fully resolved runtime configuration.
// Precedence for every field is: command-line flag, real environment
// variable, .env file, then the built-in default.
type Config struct {
	Bind         string
	TCPPort      int
	UDPPort      int
	Token        string
	NodeToken    string
	Mode         string
	ControlAddr  string
	AllowPrivate bool
	AllowNets    string
	TLSCert      string
	TLSKey       string
	Verbose      bool
	LoadedFiles  []string
}

// Summary is a single startup line. Tokens are reported only as set or unset.
func (c Config) Summary() string {
	files := "无"
	if len(c.LoadedFiles) > 0 {
		files = strings.Join(c.LoadedFiles, ", ")
	}
	return fmt.Sprintf(
		"生效配置 mode=%s bind=%s tcp_port=%d udp_port=%d control_addr=%s echo_token=%s node_token=%s allow_private=%t allow_nets=%s tls_cert=%s tls_key=%s verbose=%t 配置文件=%s",
		c.Mode,
		c.Bind,
		c.TCPPort,
		c.UDPPort,
		c.ControlAddr,
		secretState(c.Token),
		secretState(c.NodeToken),
		c.AllowPrivate,
		c.AllowNets,
		pathState(c.TLSCert),
		pathState(c.TLSKey),
		c.Verbose,
		files,
	)
}

func secretState(s string) string {
	if s == "" {
		return "未设置"
	}
	return "已设置"
}

func pathState(s string) string {
	if strings.TrimSpace(s) == "" {
		return "未设置"
	}
	return s
}

// loadConfig resolves configuration for a real process start.
// A missing .env next to the executable or in the working directory is ignored.
func loadConfig(args []string, environ []string) (Config, error) {
	exeDir := ""
	if exe, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		exeDir = filepath.Dir(exe)
	}
	cwd, err := os.Getwd()
	if err != nil {
		return Config{}, err
	}
	return loadConfigAt(args, environ, exeDir, cwd)
}

// loadConfigAt is the testable core of loadConfig.
func loadConfigAt(args []string, environ []string, exeDir, cwd string) (Config, error) {
	fs := flag.NewFlagSet("netquality-reflector", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	bind := fs.String("bind", defaultBind, "反射监听地址，对应 NQ_BIND")
	tcpPort := fs.Int("tcp-port", defaultTCPPort, "TCP 反射端口，0 表示关闭，对应 NQ_TCP_PORT")
	udpPort := fs.Int("udp-port", defaultUDPPort, "UDP 反射端口，0 表示关闭，对应 NQ_UDP_PORT")
	token := fs.String("token", "", "回显口令，最长 32 字节，留空不校验，对应 NQ_TOKEN")
	nodeToken := fs.String("node-token", "", "节点口令，留空则节点公开，对应 NQ_NODE_TOKEN")
	mode := fs.String("mode", defaultMode, "reflector、node 或 both，对应 NQ_MODE")
	controlAddr := fs.String("control-addr", defaultControlAddr, "节点控制地址，对应 NQ_CONTROL_ADDR")
	allowPrivate := fs.Bool("allow-private", false, "允许探测本机和局域网，对应 NQ_ALLOW_PRIVATE")
	allowNets := fs.String("allow-nets", "", "额外允许的网段，逗号分隔，对应 NQ_ALLOW_NETS")
	tlsCert := fs.String("tls-cert", "", "控制端口证书，对应 NQ_TLS_CERT")
	tlsKey := fs.String("tls-key", "", "控制端口私钥，对应 NQ_TLS_KEY")
	envPath := fs.String("env", "", "额外的 .env 路径，会覆盖其他 .env；文件必须存在")
	verbose := fs.Bool("v", false, "打印每一包日志，对应 NQ_VERBOSE")
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), `网络质量探测节点

优先级：命令行参数 > 环境变量 > .env 文件 > 内置默认值。
启动时读取程序所在目录和当前目录下的 .env（路径相同则只读一次）。
找不到这些 .env 不会报错。-env 指定的文件必须存在，并覆盖前面的 .env。

`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return Config{}, errHelp
		}
		return Config{}, err
	}
	if fs.NArg() != 0 {
		return Config{}, fmt.Errorf("不认识的参数: %s", strings.Join(fs.Args(), " "))
	}
	visited := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { visited[f.Name] = true })

	fileEnv, loaded, err := mergeEnvFiles(exeDir, cwd, strings.TrimSpace(*envPath))
	if err != nil {
		return Config{}, err
	}
	real := envMap(environ)

	cfg := Config{LoadedFiles: loaded}
	cfg.Bind = pickString(visited["bind"], *bind, "NQ_BIND", real, fileEnv, defaultBind)
	cfg.Token = pickString(visited["token"], *token, "NQ_TOKEN", real, fileEnv, "")
	cfg.NodeToken = pickString(visited["node-token"], *nodeToken, "NQ_NODE_TOKEN", real, fileEnv, "")
	cfg.Mode = pickString(visited["mode"], *mode, "NQ_MODE", real, fileEnv, defaultMode)
	cfg.ControlAddr = pickString(visited["control-addr"], *controlAddr, "NQ_CONTROL_ADDR", real, fileEnv, defaultControlAddr)
	cfg.AllowNets = pickString(visited["allow-nets"], *allowNets, "NQ_ALLOW_NETS", real, fileEnv, "")
	cfg.TLSCert = pickString(visited["tls-cert"], *tlsCert, "NQ_TLS_CERT", real, fileEnv, "")
	cfg.TLSKey = pickString(visited["tls-key"], *tlsKey, "NQ_TLS_KEY", real, fileEnv, "")

	tcpRaw := pickString(visited["tcp-port"], strconv.Itoa(*tcpPort), "NQ_TCP_PORT", real, fileEnv, strconv.Itoa(defaultTCPPort))
	udpRaw := pickString(visited["udp-port"], strconv.Itoa(*udpPort), "NQ_UDP_PORT", real, fileEnv, strconv.Itoa(defaultUDPPort))
	allowRaw := pickString(visited["allow-private"], strconv.FormatBool(*allowPrivate), "NQ_ALLOW_PRIVATE", real, fileEnv, "false")
	verboseRaw := pickString(visited["v"], strconv.FormatBool(*verbose), "NQ_VERBOSE", real, fileEnv, "false")

	cfg.TCPPort, err = parsePort("NQ_TCP_PORT", tcpRaw)
	if err != nil {
		return Config{}, err
	}
	cfg.UDPPort, err = parsePort("NQ_UDP_PORT", udpRaw)
	if err != nil {
		return Config{}, err
	}
	cfg.AllowPrivate, err = parseBool("NQ_ALLOW_PRIVATE", allowRaw)
	if err != nil {
		return Config{}, err
	}
	cfg.Verbose, err = parseBool("NQ_VERBOSE", verboseRaw)
	if err != nil {
		return Config{}, err
	}
	if err := cfg.validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func pickString(fromFlag bool, flagVal, envKey string, real, file map[string]string, fallback string) string {
	if fromFlag {
		return flagVal
	}
	if v, ok := real[envKey]; ok {
		return v
	}
	if v, ok := file[envKey]; ok {
		return v
	}
	return fallback
}

func (c Config) validate() error {
	switch c.Mode {
	case "reflector", "node", "both":
	default:
		return fmt.Errorf("NQ_MODE 必须是 reflector、node 或 both，当前是 %q", c.Mode)
	}
	if c.TCPPort < 0 || c.TCPPort > 65535 || c.UDPPort < 0 || c.UDPPort > 65535 {
		return fmt.Errorf("端口必须在 0 到 65535 之间")
	}
	if (c.Mode == "reflector" || c.Mode == "both") && c.TCPPort == 0 && c.UDPPort == 0 {
		return fmt.Errorf("反射模式至少要打开 TCP 或 UDP 其中一个端口")
	}
	if strings.TrimSpace(c.Bind) == "" {
		return fmt.Errorf("NQ_BIND 不能为空")
	}
	if strings.TrimSpace(c.ControlAddr) == "" {
		return fmt.Errorf("NQ_CONTROL_ADDR 不能为空")
	}
	if (c.TLSCert == "") != (c.TLSKey == "") {
		return fmt.Errorf("NQ_TLS_CERT 和 NQ_TLS_KEY 必须同时填写")
	}
	if _, err := tokenBytes(c.Token); err != nil {
		return fmt.Errorf("回显口令无效: %w", err)
	}
	if _, err := parseNets(c.AllowNets); err != nil {
		return err
	}
	return nil
}

func envMap(environ []string) map[string]string {
	out := make(map[string]string, len(environ))
	for _, entry := range environ {
		k, v, ok := strings.Cut(entry, "=")
		if !ok || k == "" {
			continue
		}
		out[k] = v
	}
	return out
}

func mergeEnvFiles(exeDir, cwd, explicit string) (map[string]string, []string, error) {
	var paths []string
	add := func(p string) {
		if strings.TrimSpace(p) == "" {
			return
		}
		for _, have := range paths {
			if samePath(have, p) {
				return
			}
		}
		paths = append(paths, p)
	}
	if exeDir != "" {
		add(filepath.Join(exeDir, ".env"))
	}
	if cwd != "" {
		add(filepath.Join(cwd, ".env"))
	}
	if explicit != "" {
		if _, err := os.Stat(explicit); err != nil {
			if os.IsNotExist(err) {
				return nil, nil, fmt.Errorf("找不到 -env 指定的文件: %s", explicit)
			}
			return nil, nil, fmt.Errorf("无法读取 -env 文件 %s: %w", explicit, err)
		}
		// The explicit file wins over the default locations.
		var rest []string
		for _, p := range paths {
			if !samePath(p, explicit) {
				rest = append(rest, p)
			}
		}
		paths = append(rest, explicit)
	}

	merged := map[string]string{}
	var loaded []string
	for _, p := range paths {
		required := explicit != "" && samePath(p, explicit)
		vals, found, err := readEnvFile(p, required)
		if err != nil {
			return nil, nil, err
		}
		if !found {
			continue
		}
		for k, v := range vals {
			merged[k] = v
		}
		loaded = append(loaded, p)
	}
	return merged, loaded, nil
}

func readEnvFile(path string, required bool) (map[string]string, bool, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) && !required {
			return nil, false, nil
		}
		if os.IsNotExist(err) {
			return nil, false, fmt.Errorf("找不到配置文件: %s", path)
		}
		return nil, false, fmt.Errorf("无法读取配置文件 %s: %w", path, err)
	}
	defer f.Close()
	vals, err := parseDotEnv(f)
	if err != nil {
		return nil, false, fmt.Errorf("%s: %w", path, err)
	}
	return vals, true, nil
}

func samePath(a, b string) bool {
	aa, ea := filepath.Abs(a)
	bb, eb := filepath.Abs(b)
	if ea != nil || eb != nil {
		return filepath.Clean(a) == filepath.Clean(b)
	}
	if ra, err := filepath.EvalSymlinks(aa); err == nil {
		aa = ra
	}
	if rb, err := filepath.EvalSymlinks(bb); err == nil {
		bb = rb
	}
	return aa == bb
}

var knownEnvKeys = map[string]struct{}{
	"NQ_BIND":          {},
	"NQ_TCP_PORT":      {},
	"NQ_UDP_PORT":      {},
	"NQ_TOKEN":         {},
	"NQ_NODE_TOKEN":    {},
	"NQ_MODE":          {},
	"NQ_CONTROL_ADDR":  {},
	"NQ_ALLOW_PRIVATE": {},
	"NQ_ALLOW_NETS":    {},
	"NQ_TLS_CERT":      {},
	"NQ_TLS_KEY":       {},
	"NQ_VERBOSE":       {},
}

func parseDotEnv(r io.Reader) (map[string]string, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	out := map[string]string{}
	lineNo := 0
	first := true
	for sc.Scan() {
		lineNo++
		line := sc.Text()
		if first {
			line = strings.TrimPrefix(line, "\uFEFF")
			first = false
		}
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "export ") {
			line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
		}
		key, raw, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("第 %d 行不是 KEY=VALUE", lineNo)
		}
		key = strings.TrimSpace(key)
		if !validEnvKey(key) {
			return nil, fmt.Errorf("第 %d 行配置名无效: %s", lineNo, key)
		}
		if _, known := knownEnvKeys[key]; !known {
			return nil, fmt.Errorf("第 %d 行不认识的配置项 %s", lineNo, key)
		}
		val, err := parseEnvValue(raw)
		if err != nil {
			return nil, fmt.Errorf("第 %d 行: %w", lineNo, err)
		}
		out[key] = val
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func validEnvKey(k string) bool {
	if k == "" {
		return false
	}
	for i, r := range k {
		if i == 0 {
			if r != '_' && !unicode.IsLetter(r) {
				return false
			}
			continue
		}
		if r != '_' && !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			return false
		}
	}
	return true
}

func parseEnvValue(raw string) (string, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "", nil
	}
	if s[0] == '"' || s[0] == '\'' {
		q := s[0]
		var b strings.Builder
		rest := s[1:]
		for i := 0; i < len(rest); i++ {
			c := rest[i]
			if c == '\\' && q == '"' && i+1 < len(rest) {
				b.WriteByte(rest[i+1])
				i++
				continue
			}
			if c == q {
				tail := strings.TrimSpace(rest[i+1:])
				if tail != "" && !strings.HasPrefix(tail, "#") {
					return "", fmt.Errorf("引号结束后还有多余内容")
				}
				return b.String(), nil
			}
			b.WriteByte(c)
		}
		return "", fmt.Errorf("引号没有结束")
	}
	if i := inlineComment(s); i >= 0 {
		s = strings.TrimSpace(s[:i])
	}
	return s, nil
}

func inlineComment(s string) int {
	for i := 0; i < len(s); i++ {
		if s[i] == '#' && (i == 0 || s[i-1] == ' ' || s[i-1] == '\t') {
			return i
		}
	}
	return -1
}

func parsePort(name, raw string) (int, error) {
	n, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || n < 0 || n > 65535 {
		return 0, fmt.Errorf("%s 必须是 0 到 65535 的整数，当前是 %q", name, raw)
	}
	return n, nil
}

func parseBool(name, raw string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "1", "true", "yes", "on":
		return true, nil
	case "0", "false", "no", "off":
		return false, nil
	default:
		return false, fmt.Errorf("%s 必须是 true 或 false，当前是 %q", name, raw)
	}
}
