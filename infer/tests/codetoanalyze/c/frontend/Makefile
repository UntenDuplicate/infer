# Copyright (c) 2016 - present Facebook, Inc.
# All rights reserved.
#
# This source code is licensed under the BSD style license found in the
# LICENSE file in the root directory of this source tree. An additional grant
# of patent rights can be found in the PATENTS file in the same directory.

TESTS_DIR=../../..

CLANG_OPTIONS = -c

SOURCES = \
  $(wildcard */*.c) \
  $(wildcard */*.cpp) \

include $(TESTS_DIR)/clang-frontend.make

compile:
	clang $(CLANG_OPTIONS) $(SOURCES)

capture:
	$(INFER_BIN) -a capture --frontend-tests --cxx -- clang $(CLANG_OPTIONS) $(SOURCES)
