CMAKE_COMMON_FLAGS ?= -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
CMAKE_DEBUG_FLAGS ?= -DUSERVER_SANITIZE='addr ub'
CMAKE_RELEASE_FLAGS ?=
CMAKE_OS_FLAGS ?= -DUSERVER_FEATURE_CRYPTOPP_BLAKE2=0 -DUSERVER_FEATURE_REDIS_HI_MALLOC=1
NPROCS ?= $(shell nproc)
CLANG_FORMAT ?= clang-format
DOCKER_COMPOSE ?= docker-compose

ifeq ($(KERNEL),Darwin)
CMAKE_COMMON_FLAGS += -DUSERVER_NO_WERROR=1 -DUSERVER_CHECK_PACKAGE_VERSIONS=0 \
  -DUSERVER_DOWNLOAD_PACKAGE_CRYPTOPP=1 \
  -DOPENSSL_ROOT_DIR=$(shell brew --prefix openssl) \
  -DUSERVER_PG_INCLUDE_DIR=$(shell pg_config --includedir) \
  -DUSERVER_PG_LIBRARY_DIR=$(shell pg_config --libdir) \
  -DUSERVER_PG_SERVER_LIBRARY_DIR=$(shell pg_config --pkglibdir) \
  -DUSERVER_PG_SERVER_INCLUDE_DIR=$(shell pg_config --includedir-server)
# Macos don't support sanitizers
CMAKE_DEBUG_FLAGS =
endif

# NOTE: use Makefile.local for customization
-include Makefile.local

.PHONY: all
all: test-debug test-release

# Debug cmake configuration
build_debug/Makefile:
	@git submodule update --init
	@mkdir -p build_debug
	@cd build_debug && \
      cmake -DCMAKE_BUILD_TYPE=Debug $(CMAKE_COMMON_FLAGS) $(CMAKE_DEBUG_FLAGS) $(CMAKE_OS_FLAGS) $(CMAKE_OPTIONS) ..

# Release cmake configuration
build_release/Makefile:
	@git submodule update --init
	@mkdir -p build_release
	@cd build_release && \
      cmake -DCMAKE_BUILD_TYPE=Release $(CMAKE_COMMON_FLAGS) $(CMAKE_RELEASE_FLAGS) $(CMAKE_OS_FLAGS) $(CMAKE_OPTIONS) ..

# Run cmake
.PHONY: cmake-debug cmake-release
cmake-debug cmake-release: cmake-%: build_%/Makefile

# Build using cmake
.PHONY: build-debug build-release
build-debug build-release: build-%: cmake-%
	@cmake --build build_$* -j $(NPROCS) --target pg_service_template

# Test
.PHONY: test-debug test-release
test-debug test-release: test-%: build-%
	@cmake --build build_$* -j $(NPROCS) --target pg_service_template_unittest
	@cmake --build build_$* -j $(NPROCS) --target pg_service_template_benchmark
	@cd build_$* && ((test -t 1 && GTEST_COLOR=1 PYTEST_ADDOPTS="--color=yes" ctest -V) || ctest -V)
	@pep8 tests

# Start the service (via testsuite service runner)
.PHONY: service-start-debug service-start-release
service-start-debug service-start-release: service-start-%: build-%
	@cd ./build_$* && $(MAKE) start-pg_service_template

# Cleanup data
.PHONY: clean-debug clean-release
clean-debug clean-release: clean-%:
	cd build_$* && $(MAKE) clean

.PHONY: dist-clean
dist-clean:
	@rm -rf build_*
	@rm -rf tests/__pycache__/
	@rm -rf tests/.pytest_cache/

# Install
.PHONY: install-debug install-release
install-debug install-release: install-%: build-%
	@cd build_$* && \
		cmake --install . -v --component pg_service_template

.PHONY: install
install: install-release

# Format the sources
.PHONY: format
format:
	@find src -name '*pp' -type f | xargs $(CLANG_FORMAT) -i
	@find tests -name '*.py' -type f | xargs autopep8 -i

# Internal hidden targets that are used only in docker environment
--in-docker-start-debug --in-docker-start-release: --in-docker-start-%: install-%
	@psql 'postgresql://user:password@service-postgres:5432/pg_service_template_db-1' -f ./postgresql/data/initial_data.sql
	@/home/user/.local/bin/pg_service_template \
		--config /home/user/.local/etc/pg_service_template/static_config.yaml \
		--config_vars /home/user/.local/etc/pg_service_template/config_vars.docker.yaml

# Build and run service in docker environment
.PHONY: docker-start-service-debug docker-start-service-release
docker-start-service-debug docker-start-service-release: docker-start-service-%:
	@$(DOCKER_COMPOSE) run -p 8080:8080 --rm pg_service_template-container make -- --in-docker-start-$*

# Start targets makefile in docker environment
.PHONY: docker-cmake-debug docker-build-debug docker-test-debug docker-clean-debug docker-install-debug docker-cmake-release docker-build-release docker-test-release docker-clean-release docker-install-release
docker-cmake-debug docker-build-debug docker-test-debug docker-clean-debug docker-install-debug docker-cmake-release docker-build-release docker-test-release docker-clean-release docker-install-release: docker-%:
	$(DOCKER_COMPOSE) run --rm pg_service_template-container make $*

# Stop docker container and remove PG data
.PHONY: docker-clean-data
docker-clean-data:
	@$(DOCKER_COMPOSE) down -v
	@rm -rf ./.pgdata
