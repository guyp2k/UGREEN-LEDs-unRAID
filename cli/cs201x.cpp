#include "cs201x.h"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <iomanip>
#include <sstream>
#include <sys/file.h>
#include <sys/io.h>
#include <unistd.h>

namespace {

class system_port_io_t final : public cs201x_port_io_t {
public:
    int request(unsigned long first, unsigned long count) override {
        if (ioperm(first, count, 1) == 0)
            return 0;
        return -errno;
    }

    void release(unsigned long first, unsigned long count) override {
        ioperm(first, count, 0);
    }

    uint8_t read(uint16_t port) override {
        return inb(port);
    }

    void write(uint16_t port, uint8_t value) override {
        outb(value, port);
    }
};

std::string errno_message(const std::string& context, int error) {
    std::ostringstream message;
    message << context;
    if (error < 0)
        message << ": " << std::strerror(-error);
    return message.str();
}

} // namespace

cs201x_device_t::cs201x_device_t()
    : _owned_port_io(std::make_unique<system_port_io_t>()),
      _port_io(_owned_port_io.get()),
      _system_access(true) {
}

cs201x_device_t::cs201x_device_t(cs201x_port_io_t& port_io)
    : _port_io(&port_io) {
}

cs201x_device_t::~cs201x_device_t() {
    cleanup();
}

int cs201x_device_t::fail(int error, const std::string& message) {
    _last_error = errno_message(message, error);
    cleanup();
    return error;
}

int cs201x_device_t::acquire_lock() {
    if (!_system_access)
        return 0;

    _lock_fd = open("/run/lock/ugreen-leds-cs201x.lock",
                    O_CREAT | O_CLOEXEC | O_RDWR, 0600);
    if (_lock_fd < 0)
        return -errno;

    if (flock(_lock_fd, LOCK_EX) < 0) {
        int error = -errno;
        close(_lock_fd);
        _lock_fd = -1;
        return error;
    }

    return 0;
}

void cs201x_device_t::cleanup() {
    _ready = false;

    if (_ec_ports_requested) {
        _port_io->release(_ec_base, 9);
        _ec_ports_requested = false;
    }
    if (_sio_ports_requested) {
        _port_io->release(SIO_INDEX_PORT, 2);
        _sio_ports_requested = false;
    }
    if (_lock_fd >= 0) {
        close(_lock_fd);
        _lock_fd = -1;
    }
}

void cs201x_device_t::sio_enter() {
    _port_io->write(SIO_INDEX_PORT, 0xa5);
    _port_io->write(SIO_INDEX_PORT, 0x69);
    _port_io->write(SIO_INDEX_PORT, 0x87);
}

void cs201x_device_t::sio_exit() {
    _port_io->write(SIO_INDEX_PORT, 0x87);
    _port_io->write(SIO_INDEX_PORT, 0x69);
    _port_io->write(SIO_INDEX_PORT, 0xa5);
}

uint8_t cs201x_device_t::sio_read(uint8_t index) {
    _port_io->write(SIO_INDEX_PORT, index);
    return _port_io->read(SIO_DATA_PORT);
}

void cs201x_device_t::sio_write(uint8_t index, uint8_t value) {
    _port_io->write(SIO_INDEX_PORT, index);
    _port_io->write(SIO_DATA_PORT, value);
}

void cs201x_device_t::ec_select(uint32_t address) {
    _port_io->write(_ec_base + 1, 0);
    _port_io->write(_ec_base + 7, static_cast<uint8_t>(address >> 24));
    _port_io->write(_ec_base + 6, static_cast<uint8_t>(address >> 16));
    _port_io->write(_ec_base + 5, static_cast<uint8_t>(address >> 8));
    _port_io->write(_ec_base + 4, static_cast<uint8_t>(address));
}

uint8_t cs201x_device_t::ec_read8_unchecked(uint32_t address) {
    ec_select(address);
    return _port_io->read(_ec_base + 8);
}

void cs201x_device_t::ec_write8_unchecked(uint32_t address, uint8_t value) {
    ec_select(address);
    _port_io->write(_ec_base + 8, value);
}

int cs201x_device_t::start() {
    if (_ready)
        return 0;

    _last_error.clear();

    if (_system_access && access("/sys/module/ug_201x_sio", F_OK) == 0)
        return fail(-EBUSY, "vendor ug_201x_sio driver is loaded");

    int error = acquire_lock();
    if (error < 0)
        return fail(error, "cannot lock the CS201x controller");

    error = _port_io->request(SIO_INDEX_PORT, 2);
    if (error < 0)
        return fail(error, "cannot access Super-I/O ports 0x2e-0x2f");
    _sio_ports_requested = true;

    sio_enter();
    _chip_id = (static_cast<uint16_t>(sio_read(0x20)) << 8) |
               sio_read(0x21);
    _revision = (static_cast<uint16_t>(sio_read(0x22)) << 8) |
                sio_read(0x23);

    if (_chip_id != EXPECTED_CHIP_ID) {
        sio_exit();
        std::ostringstream message;
        message << "unexpected Super-I/O chip id 0x" << std::hex
                << std::setw(4) << std::setfill('0') << _chip_id
                << " (expected 0x2011)";
        return fail(-ENODEV, message.str());
    }

    sio_write(0x07, EC_LDN);
    _ec_base = (static_cast<uint16_t>(sio_read(0x60)) << 8) |
               sio_read(0x61);
    if (_ec_base == 0 || static_cast<unsigned int>(_ec_base) + 8 > 0xffffu) {
        sio_exit();
        std::ostringstream message;
        message << "invalid CS201x runtime EC base 0x" << std::hex << _ec_base;
        return fail(-ENODEV, message.str());
    }

    error = _port_io->request(_ec_base, 9);
    if (error < 0) {
        sio_exit();
        std::ostringstream message;
        message << "cannot access CS201x runtime ports 0x" << std::hex
                << _ec_base << "-0x" << (_ec_base + 8);
        return fail(error, message.str());
    }
    _ec_ports_requested = true;

    // Activate logical device 0x0a and reproduce only the four platform
    // enables performed before the vendor driver's LED initialization.
    sio_write(0x30, 1);
    ec_write8_unchecked(0x200053f0u, 1);
    ec_write8_unchecked(0x200053f1u, 1);
    ec_write8_unchecked(0x20005370u, 1);
    ec_write8_unchecked(0x20005371u, 1);

    sio_exit();
    _port_io->release(SIO_INDEX_PORT, 2);
    _sio_ports_requested = false;
    _ready = true;
    return 0;
}

int cs201x_device_t::read8(uint32_t address, uint8_t& value) {
    if (!_ready)
        return -ENODEV;

    value = ec_read8_unchecked(address);
    return 0;
}

int cs201x_device_t::write8(uint32_t address, uint8_t value) {
    if (!_ready)
        return -ENODEV;

    ec_write8_unchecked(address, value);
    return 0;
}

int cs201x_device_t::write_verified(uint32_t address, uint8_t value) {
    int error = write8(address, value);
    if (error < 0)
        return error;

    uint8_t actual;
    if (read8(address, actual) < 0 || actual != value) {
        std::ostringstream message;
        message << "CS201x EC register 0x" << std::hex << address
                << " did not retain value 0x" << std::setw(2)
                << std::setfill('0') << static_cast<unsigned int>(value);
        _last_error = message.str();
        return -EIO;
    }

    return 0;
}

int cs201x_device_t::get_status(uint8_t id, led_status_t& status) {
    if (!valid_led(id))
        return -EINVAL;

    uint8_t cycle_ticks;
    uint8_t on_ticks;
    if (read8(LED_MODE_BASE + id, status.mode) < 0 ||
            read8(LED_BRIGHTNESS_BASE + id, status.brightness) < 0 ||
            read8(LED_CYCLE_BASE + id, cycle_ticks) < 0 ||
            read8(LED_ON_TIME_BASE + id, on_ticks) < 0) {
        return -EIO;
    }
    if (status.mode > 3)
        return -EIO;

    uint32_t rgb_base = LED_RGB_BASE + 4u * id;
    if (read8(rgb_base + 1, status.red) < 0 ||
            read8(rgb_base + 2, status.green) < 0 ||
            read8(rgb_base, status.blue) < 0) {
        return -EIO;
    }

    status.t_on = static_cast<uint16_t>(on_ticks) * 50u;
    status.t_off = cycle_ticks >= on_ticks
        ? static_cast<uint16_t>(cycle_ticks - on_ticks) * 50u
        : 0;
    return 0;
}

int cs201x_device_t::set_mode(uint8_t id, uint8_t mode,
        uint16_t t_on, uint16_t t_off) {
    if (!valid_led(id) || mode > 3)
        return -EINVAL;

    uint32_t cycle_ticks =
        (static_cast<uint32_t>(t_on) + t_off) / 50u;
    uint32_t on_ticks = t_on / 50u;
    if (cycle_ticks > 0xffu || on_ticks > 0xffu) {
        _last_error = "CS201x blink/breath timing exceeds 12750 ms";
        return -ERANGE;
    }

    int error = write_verified(LED_MODE_BASE + id, mode);
    if (error < 0)
        return error;
    error = write_verified(LED_CYCLE_BASE + id,
            static_cast<uint8_t>(cycle_ticks));
    if (error < 0)
        return error;
    return write_verified(LED_ON_TIME_BASE + id,
            static_cast<uint8_t>(on_ticks));
}

int cs201x_device_t::set_onoff(uint8_t id, bool on) {
    return set_mode(id, on ? 1 : 0, 0, 0);
}

int cs201x_device_t::set_rgb(uint8_t id, uint8_t red, uint8_t green,
        uint8_t blue) {
    if (!valid_led(id))
        return -EINVAL;

    uint32_t rgb_base = LED_RGB_BASE + 4u * id;
    int error = write_verified(rgb_base, blue);
    if (error < 0)
        return error;
    error = write_verified(rgb_base + 1, red);
    if (error < 0)
        return error;
    return write_verified(rgb_base + 2, green);
}

int cs201x_device_t::set_brightness(uint8_t id, uint8_t brightness) {
    if (!valid_led(id))
        return -EINVAL;
    if (brightness == 0)
        return set_onoff(id, false);
    if (brightness == 1)
        return set_onoff(id, true);
    return write_verified(LED_BRIGHTNESS_BASE + id, brightness);
}

int cs201x_device_t::set_blink(uint8_t id, uint16_t t_on, uint16_t t_off) {
    if (!valid_led(id))
        return -EINVAL;
    if (t_on == 0 || t_off == 0)
        return 0;
    if (t_on < 100)
        t_on = 100;
    if (t_off < 100)
        t_off = 100;
    return set_mode(id, 2, t_on, t_off);
}

int cs201x_device_t::set_breath(uint8_t id, uint16_t t_on, uint16_t t_off) {
    if (!valid_led(id))
        return -EINVAL;
    if (t_on == 0 || t_off == 0)
        return 0;
    if (t_on < 1000)
        t_on = 1000;
    if (t_off < 500)
        t_off = 500;
    return set_mode(id, 3, t_on, t_off);
}
