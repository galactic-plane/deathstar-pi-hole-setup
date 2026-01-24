# Death Star Pi-hole Setup Documentation

Comprehensive documentation for the Death Star Pi-hole Setup project, organized by environment and script functionality.

---

## Documentation Structure

```
docs/
├── README.md          # This file - Documentation index
├── host/              # Host environment scripts documentation
│   └── README.md      # Detailed docs for development/deployment scripts
└── pi/                # Raspberry Pi environment scripts documentation
    └── README.md      # Detailed docs for Pi installation/management scripts
```

---

## Quick Navigation

### Host Environment (Development Machine)
**Scripts that run on your development/host computer**

| Script | Purpose | Documentation |
|--------|---------|---------------|
| `push_to_pi.sh` | Deploy files to Pi via rsync | [Host Scripts](host/README.md#push_to_pi.sh) |
| `connect_to_pi.sh` | SSH connection with automated setup | [Host Scripts](host/README.md#connect_to_pi.sh) |
| `integrity-check.sh` | Pre-deployment validation | [Host Scripts](host/README.md#integrity-check.sh) |
| `config_loader.sh` | Configuration management library | [Host Scripts](host/README.md#config_loader.sh) |

### Raspberry Pi Environment (Target System)
**Scripts that run on your Raspberry Pi**

| Script | Purpose | Documentation |
|--------|---------|---------------|
| `setup.sh` | Complete Pi-hole system installation | [Pi Scripts](pi/README.md#setup.sh) |
| `status.sh` | System health and diagnostics | [Pi Scripts](pi/README.md#status.sh) |
| `update.sh` | Update all installed services | [Pi Scripts](pi/README.md#update.sh) |
| `remove.sh` | Complete system removal | [Pi Scripts](pi/README.md#remove.sh) |

---

## Getting Started

### New Users
1. **Start Here**: [Main Project README](../README.md)
2. **Host Scripts**: [Host Environment Documentation](host/README.md)
3. **Pi Scripts**: [Pi Environment Documentation](pi/README.md)

### Specific Use Cases

#### Setting Up Development Environment
- [Host Scripts: push_to_pi.sh](host/README.md#push_to_pi.sh)
- [Host Scripts: connect_to_pi.sh](host/README.md#connect_to_pi.sh)

#### Installing Pi-hole System
- [Pi Scripts: setup.sh](pi/README.md#setup.sh)

#### Monitoring and Maintenance
- [Pi Scripts: status.sh](pi/README.md#status.sh)
- [Pi Scripts: update.sh](pi/README.md#update.sh)

#### Troubleshooting Issues
- [Host Scripts: integrity-check.sh](host/README.md#integrity-check.sh)
- [Pi Scripts: status.sh](pi/README.md#status.sh)

#### Removing Installation
- [Pi Scripts: remove.sh](pi/README.md#remove.sh)

---

## Documentation Features

### Detailed Script Analysis
Each script documentation includes:
- **Exact functionality** - What the script does step-by-step
- **System requirements** - Prerequisites and dependencies
- **Usage examples** - Common use cases and command syntax
- **Configuration options** - Available settings and customization
- **Error handling** - Common issues and solutions
- **Exit codes** - Return codes and their meanings

### Environment-Specific Guidance
- **Host Environment**: Development tools and deployment scripts
- **Pi Environment**: Installation, monitoring, and maintenance scripts
- **Cross-Environment**: How scripts interact between environments

### Comprehensive Coverage
- **Pre-installation requirements** that scripts don't install themselves
- **Runtime dependencies** needed for execution
- **Optional tools** for enhanced functionality
- **Network and security requirements**

---

## Related Documentation

### Project Documentation
- [Main README](../README.md) - Project overview and quick start
- [Configuration](../config.json) - Master configuration file
- [License](../LICENSE) - Project license information

### External Resources
- [Pi-hole Documentation](https://docs.pi-hole.net/)
- [Grafana Documentation](https://grafana.com/docs/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Docker Documentation](https://docs.docker.com/)

---

## Documentation Stats

| Environment | Scripts | Lines of Code | Documentation |
|-------------|---------|---------------|---------------|
| Host | 4 scripts | ~2,500 lines | [Detailed docs](host/README.md) |
| Pi | 4 main + 4 lib | ~6,500 lines | [Detailed docs](pi/README.md) |
| **Total** | **12 components** | **~9,000 lines** | **Complete coverage** |

---

## Documentation Maintenance

### Keeping Docs Updated
- Documentation reflects current script functionality
- Examples tested with actual script versions
- Requirements verified with target systems
- Links validated and functional

### Contributing to Documentation
- Follow existing format and structure
- Include practical examples
- Test all commands and procedures
- Update index files when adding new docs

---

## Tips for Using Documentation

### Finding Information Quickly
- Use **Ctrl+F** to search within documentation files
- Check the **Table of Contents** in each README
- Use **cross-references** between related scripts
- Refer to **exit codes** for troubleshooting

### Understanding Script Relationships
- **Host scripts** prepare and deploy to Pi
- **Pi scripts** install and manage services
- **Library scripts** provide shared functionality
- **Configuration** controls behavior across environments

### Getting Help
1. Check relevant documentation section
2. Look for **common issues** and solutions
3. Review **system requirements**
4. Check **exit codes** for error diagnosis
5. Use **status.sh** for system diagnostics

---

**Happy Death Star Pi building!**