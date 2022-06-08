# Variables and recipes in development.*.mk are meant to be used from
# any Git clone. They are excluded from the files published to Hex.pm.
# Generated files are published to Hex.pm however so people using this
# source won't have to depend on Python and rabbitmq-codegen.

BUILD_DEPS = rabbitmq_codegen
TEST_DEPS = proper

CODEGEN_SOURCES += include/rabbit_framing.hrl				\
				   src/rabbit_framing_amqp_0_9_1.erl

codegen-clean:
	$(gen_verbose) rm -f $(CODEGEN_SOURCES)

codegen: codegen-clean
	$(CODEGEN_SOURCES)

.PHONY: codegen codegen-clean

$(PROJECT).d:: $(EXTRA_SOURCES)
