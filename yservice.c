#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define YSERVICE_VERSION "1.0"
#define CONF_PATH "/etc/yservice/conf.y"
#define MAX_SERVICES 128
#define MAX_LINE 512
#define LEVEL_TIMEOUT_SEC 15

typedef enum { HC_FILE, HC_PROCESS, HC_COMMAND } HealthcheckType;

typedef enum {
  STATUS_PENDING,
  STATUS_RUNNING,
  STATUS_READY,
  STATUS_FAILED
} ServiceStatus;

typedef struct {
  int level;
  char name[128];
  HealthcheckType hc_type;
  char hc_target[256];
  pid_t pid;
  ServiceStatus status;
} Service;

static Service g_services[MAX_SERVICES];
static int g_service_count = 0;

static void str_trim(char *s) {
  size_t len;
  if (!s)
    return;
  len = strlen(s);
  while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r' ||
                     s[len - 1] == ' ' || s[len - 1] == '\t')) {
    s[--len] = '\0';
  }
}

static int parse_config(void) {
  FILE *fp;
  char line[MAX_LINE];
  int lineno = 0;

  fp = fopen(CONF_PATH, "r");
  if (!fp) {
    fprintf(stderr, "yservice: cannot open %s: ", CONF_PATH);
    perror("");
    return -1;
  }

  g_service_count = 0;

  while (fgets(line, sizeof(line), fp)) {
    char *p_level, *p_name, *p_type, *p_target;
    Service *svc;

    lineno++;
    str_trim(line);

    if (line[0] == '\0' || line[0] == '#')
      continue;

    if (g_service_count >= MAX_SERVICES) {
      fprintf(stderr,
              "yservice: maximum service count (%d) exceeded at line %d\n",
              MAX_SERVICES, lineno);
      fclose(fp);
      return -1;
    }

    p_level = line;

    p_name = strchr(p_level, ':');
    if (!p_name)
      goto parse_err;
    *p_name++ = '\0';

    p_type = strchr(p_name, ':');
    if (!p_type)
      goto parse_err;
    *p_type++ = '\0';

    p_target = strchr(p_type, ':');
    if (!p_target)
      goto parse_err;
    *p_target++ = '\0';

    svc = &g_services[g_service_count];
    memset(svc, 0, sizeof(*svc));

    svc->level = atoi(p_level);
    if (svc->level < 0) {
      fprintf(stderr, "yservice: invalid level at line %d\n", lineno);
      fclose(fp);
      return -1;
    }

    strncpy(svc->name, p_name, sizeof(svc->name) - 1);

    if (strcmp(p_type, "file") == 0)
      svc->hc_type = HC_FILE;
    else if (strcmp(p_type, "process") == 0)
      svc->hc_type = HC_PROCESS;
    else if (strcmp(p_type, "command") == 0)
      svc->hc_type = HC_COMMAND;
    else {
      fprintf(stderr, "yservice: unknown healthcheck type '%s' at line %d\n",
              p_type, lineno);
      fclose(fp);
      return -1;
    }

    strncpy(svc->hc_target, p_target, sizeof(svc->hc_target) - 1);
    svc->pid = 0;
    svc->status = STATUS_PENDING;

    g_service_count++;
    continue;

  parse_err:
    fprintf(stderr, "yservice: malformed line %d in %s\n", lineno, CONF_PATH);
    fclose(fp);
    return -1;
  }

  fclose(fp);
  return 0;
}

static int check_health(const Service *svc) {
  switch (svc->hc_type) {
  case HC_FILE: {
    struct stat st;
    return (stat(svc->hc_target, &st) == 0) ? 1 : 0;
  }
  case HC_PROCESS: {
    char cmd[384];
    int rc;
    snprintf(cmd, sizeof(cmd), "pidof %s >/dev/null 2>&1", svc->hc_target);
    rc = system(cmd);
    return (WIFEXITED(rc) && WEXITSTATUS(rc) == 0) ? 1 : 0;
  }
  case HC_COMMAND: {
    char cmd[384];
    int rc;
    snprintf(cmd, sizeof(cmd), "%s >/dev/null 2>&1", svc->hc_target);
    rc = system(cmd);
    return (WIFEXITED(rc) && WEXITSTATUS(rc) == 0) ? 1 : 0;
  }
  }
  return 0;
}

static int max_level(void) {
  int i, m = 0;
  for (i = 0; i < g_service_count; i++) {
    if (g_services[i].level > m)
      m = g_services[i].level;
  }
  return m;
}

static pid_t launch_service(const char *name) {
  pid_t pid = fork();
  if (pid < 0) {
    perror("yservice: fork");
    return -1;
  }
  if (pid == 0) {
    freopen("/dev/null", "w", stdout);
    freopen("/dev/null", "w", stderr);
    char *argv[] = {(char *)name, "start", NULL};
    execvp(name, argv);
    _exit(127);
  }
  return pid;
}

static int cmd_boot(void) {
  int lvl, max_lvl, i;
  time_t t_start;
  int all_done;

  if (getuid() != 0) {
    fprintf(stderr, "yservice: boot requires root privileges\n");
    return 1;
  }

  if (parse_config() != 0)
    return 1;

  if (g_service_count == 0) {
    printf("yservice: no services configured\n");
    return 0;
  }

  max_lvl = max_level();

  printf("yservice: booting %d service(s) across levels 0..%d\n",
         g_service_count, max_lvl);

  for (lvl = 0; lvl <= max_lvl; lvl++) {
    int level_count = 0;

    printf("\n── level %d ──\n", lvl);

    for (i = 0; i < g_service_count; i++) {
      if (g_services[i].level != lvl)
        continue;

      printf("  starting %-20s ... ", g_services[i].name);
      fflush(stdout);

      g_services[i].pid = launch_service(g_services[i].name);
      if (g_services[i].pid > 0) {
        g_services[i].status = STATUS_RUNNING;
        printf("pid %d\n", (int)g_services[i].pid);
      } else {
        g_services[i].status = STATUS_FAILED;
        printf("FORK FAILED\n");
      }
      level_count++;
    }

    if (level_count == 0)
      continue;

    t_start = time(NULL);

    while (1) {
      double elapsed = difftime(time(NULL), t_start);

      if (elapsed >= (double)LEVEL_TIMEOUT_SEC) {
        printf("  *** Timeout reached for level %d ***\n", lvl);
        for (i = 0; i < g_service_count; i++) {
          if (g_services[i].level == lvl &&
              g_services[i].status == STATUS_RUNNING) {
            g_services[i].status = STATUS_FAILED;
            printf("  %-20s FAILED (timeout)\n", g_services[i].name);
          }
        }
        break;
      }

      all_done = 1;
      for (i = 0; i < g_service_count; i++) {
        if (g_services[i].level != lvl)
          continue;
        if (g_services[i].status != STATUS_RUNNING)
          continue;

        if (check_health(&g_services[i])) {
          g_services[i].status = STATUS_READY;
          printf("  %-20s READY\n", g_services[i].name);
        } else {
          all_done = 0;
        }
      }

      if (all_done)
        break;

      sleep(1);
    }
  }

  printf("\n── boot summary ──\n");
  printf("  %-20s %-6s  %s\n", "SERVICE", "LEVEL", "STATUS");
  printf("  %-20s %-6s  %s\n", "───────", "─────", "──────");
  for (i = 0; i < g_service_count; i++) {
    const char *st;
    switch (g_services[i].status) {
    case STATUS_READY:
      st = "READY";
      break;
    case STATUS_FAILED:
      st = "FAILED";
      break;
    case STATUS_RUNNING:
      st = "RUNNING";
      break;
    default:
      st = "PENDING";
      break;
    }
    printf("  %-20s %-6d  %s\n", g_services[i].name, g_services[i].level, st);
  }

  return 0;
}

static int cmd_start(const char *name) {
  pid_t pid;

  if (getuid() != 0) {
    fprintf(stderr, "yservice: start requires root privileges\n");
    return 1;
  }

  printf("yservice: starting %s ... ", name);
  fflush(stdout);

  pid = launch_service(name);
  if (pid > 0) {
    printf("pid %d\n", (int)pid);
    return 0;
  }

  printf("FAILED\n");
  return 1;
}

static int cmd_stop(const char *name) {
  char cmd[384];
  int rc;

  if (getuid() != 0) {
    fprintf(stderr, "yservice: stop requires root privileges\n");
    return 1;
  }

  printf("yservice: stopping %s ... ", name);
  fflush(stdout);

  snprintf(cmd, sizeof(cmd), "pkill %s >/dev/null 2>&1", name);
  rc = system(cmd);

  if (WIFEXITED(rc) && WEXITSTATUS(rc) == 0) {
    printf("OK\n");
    return 0;
  }

  printf("NOT FOUND\n");
  return 1;
}

static int cmd_status(void) {
  int i;

  if (parse_config() != 0)
    return 1;

  if (g_service_count == 0) {
    printf("yservice: no services configured in %s\n", CONF_PATH);
    return 0;
  }

  printf("\n  %-20s %-6s  %-10s  %s\n", "SERVICE", "LEVEL", "STATE",
         "HEALTHCHECK");
  printf("  %-20s %-6s  %-10s  %s\n", "───────", "─────", "─────",
         "───────────");

  for (i = 0; i < g_service_count; i++) {
    const char *state;
    const char *hc_label;

    state = check_health(&g_services[i]) ? "ONLINE" : "OFFLINE";

    switch (g_services[i].hc_type) {
    case HC_FILE:
      hc_label = "file";
      break;
    case HC_PROCESS:
      hc_label = "process";
      break;
    case HC_COMMAND:
      hc_label = "command";
      break;
    default:
      hc_label = "?";
      break;
    }

    printf("  %-20s %-6d  %-10s  %s:%s\n", g_services[i].name,
           g_services[i].level, state, hc_label, g_services[i].hc_target);
  }

  printf("\n");
  return 0;
}

static void usage(void) {
  fprintf(
      stderr,
      "yservice %s — y2OS Service Manager\n"
      "\n"
      "Usage:\n"
      "  yservice boot             Boot all services by level\n"
      "  yservice start <service>  Start a single service\n"
      "  yservice stop  <service>  Stop a single service\n"
      "  yservice status           Show status of all services\n"
      "\n"
      "Configuration: %s\n"
      "Format:        level:service_name:healthcheck_type:healthcheck_target\n"
      "\n"
      "Healthcheck types:\n"
      "  file      Check if a file/socket exists (stat)\n"
      "  process   Check if a process is running (pidof)\n"
      "  command   Execute a command and check exit code\n"
      "\n",
      YSERVICE_VERSION, CONF_PATH);
}

int main(int argc, char *argv[]) {
  if (argc < 2) {
    usage();
    return 1;
  }

  if (strcmp(argv[1], "boot") == 0) {
    return cmd_boot();
  }

  if (strcmp(argv[1], "start") == 0) {
    if (argc < 3) {
      fprintf(stderr, "yservice: missing service name\n");
      fprintf(stderr, "Usage: yservice start <service>\n");
      return 1;
    }
    return cmd_start(argv[2]);
  }

  if (strcmp(argv[1], "stop") == 0) {
    if (argc < 3) {
      fprintf(stderr, "yservice: missing service name\n");
      fprintf(stderr, "Usage: yservice stop <service>\n");
      return 1;
    }
    return cmd_stop(argv[2]);
  }

  if (strcmp(argv[1], "status") == 0) {
    return cmd_status();
  }

  if (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-v") == 0) {
    printf("yservice %s\n", YSERVICE_VERSION);
    return 0;
  }

  fprintf(stderr, "yservice: unknown command '%s'\n", argv[1]);
  usage();
  return 1;
}
