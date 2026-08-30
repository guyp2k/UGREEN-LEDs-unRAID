#ifndef __UGREEN_CS201X_H__
#define __UGREEN_CS201X_H__

#include <cstdint>
#include <memory>
#include <string>

class cs201x_port_io_t {
public:
    virtual ~cs201x_port_io_t() = default;

    virtual int request(unsigned long first, unsigned long count) = 0;
    virtual void release(unsigned long first, unsigned long count) = 0;
    virtual uint8_t read(uint16_t port) = 0;
    virtual void write(uint16_t port, uint8_t value) = 0;
};

class cs201x_device_t {
public:
    struct led_status_t {
        uint8_t mode;
        uint8_t brightness;
        uint8_t red;
        uint8_t green;
        uint8_t blue;
        uint16_t t_on;
        uint16_t t_off;
    };

    cs201x_device_t();
    explicit cs201x_device_t(cs201x_port_io_t& port_io);
    ~cs201x_device_t();

    cs201x_device_t(const cs201x_device_t&) = delete;
    cs201x_device_t& operator=(const cs201x_device_t&) = delete;

    int start();
    int get_status(uint8_t id, led_status_t& status);
    int set_onoff(uint8_t id, bool on);
    int set_rgb(uint8_t id, uint8_t red, uint8_t green, uint8_t blue);
    int set_brightness(uint8_t id, uint8_t brightness);
    int set_blink(uint8_t id, uint16_t t_on, uint16_t t_off);
    int set_breath(uint8_t id, uint16_t t_on, uint16_t t_off);

    bool is_ready() const { return _ready; }
    uint16_t chip_id() const { return _chip_id; }
    uint16_t revision() const { return _revision; }
    uint16_t ec_base() const { return _ec_base; }
    const std::string& last_error() const { return _last_error; }

private:
    static constexpr uint16_t SIO_INDEX_PORT = 0x2e;
    static constexpr uint16_t SIO_DATA_PORT = 0x2f;
    static constexpr uint16_t EXPECTED_CHIP_ID = 0x2011;
    static constexpr uint8_t EC_LDN = 0x0a;
    static constexpr uint32_t LED_MODE_BASE = 0x20005400u;
    static constexpr uint32_t LED_BRIGHTNESS_BASE = 0x20005404u;
    static constexpr uint32_t LED_CYCLE_BASE = 0x20005408u;
    static constexpr uint32_t LED_ON_TIME_BASE = 0x2000540cu;
    static constexpr uint32_t LED_RGB_BASE = 0x20005444u;
    static constexpr uint8_t LED_COUNT = 4;

    std::unique_ptr<cs201x_port_io_t> _owned_port_io;
    cs201x_port_io_t *_port_io = nullptr;
    bool _system_access = false;
    bool _sio_ports_requested = false;
    bool _ec_ports_requested = false;
    bool _ready = false;
    int _lock_fd = -1;
    uint16_t _chip_id = 0;
    uint16_t _revision = 0;
    uint16_t _ec_base = 0;
    std::string _last_error;

    int acquire_lock();
    void cleanup();
    void sio_enter();
    void sio_exit();
    uint8_t sio_read(uint8_t index);
    void sio_write(uint8_t index, uint8_t value);
    void ec_select(uint32_t address);
    uint8_t ec_read8_unchecked(uint32_t address);
    void ec_write8_unchecked(uint32_t address, uint8_t value);
    int read8(uint32_t address, uint8_t& value);
    int write8(uint32_t address, uint8_t value);
    int write_verified(uint32_t address, uint8_t value);
    int set_mode(uint8_t id, uint8_t mode, uint16_t t_on, uint16_t t_off);
    bool valid_led(uint8_t id) const { return id < LED_COUNT; }
    int fail(int error, const std::string& message);
};

#endif
