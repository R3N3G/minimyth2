LINUX_HEADERS_MAJOR_VERSION = 4
LINUX_HEADERS_MINOR_VERSION = 19
LINUX_HEADERS_TEENY_VERSION = 
LINUX_HEADERS_EXTRA_VERSION = 

LINUX_HEADERS_VERSION = $(LINUX_HEADERS_MAJOR_VERSION).$(LINUX_HEADERS_MINOR_VERSION)$(if $(LINUX_HEADERS_TEENY_VERSION),.$(LINUX_HEADERS_TEENY_VERSION))$(LINUX_HEADERS_EXTRA_VERSION)
LINUX_HEADERS_FULL_VERSION = $(LINUX_HEADERS_VERSION)
