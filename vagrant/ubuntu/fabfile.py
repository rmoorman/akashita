# -*- coding: utf-8 -*-
# -------------------------------------------------------------------
#
# Copyright (c) 2014-2016 Nathan Fiedler
#
# This file is provided to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file
# except in compliance with the License. You may obtain
# a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the
# specific language governing permissions and limitations
# under the License.
#
# -------------------------------------------------------------------
"""Fabric file for installing requirements on Ubuntu Linux."""

import os

from fabric.api import cd, env, run, sudo, task

env.hosts = ["default"]
env.use_ssh_config = True
if os.path.exists("user_ssh_config"):
    env.ssh_config_path = "user_ssh_config"
else:
    env.ssh_config_path = "ssh_config"

DIR_OTP = 'otp_src_18.2.1'
TAR_OTP = '{}.tar.gz'.format(DIR_OTP)
URL_OTP = 'http://erlang.org/download/{}'.format(TAR_OTP)


@task
def all():
    """Install everything needed for akashita."""
    install_erlang()
    install_rebar()


@task
def install_erlang():
    """Install Erlang/OTP."""
    # Install the compilers, JDK, and XML tools
    pre_reqs = [
        'build-essential',
        'libncurses5-dev',
        'libssl-dev',
    ]
    sudo('apt-get -q -y install {}'.format(' '.join(pre_reqs)))
    # Prepare to build Erlang/OTP from source
    run('wget -q {}'.format(URL_OTP))
    run('tar zxf {}'.format(TAR_OTP))
    with cd(DIR_OTP):
        run('./configure')
        run('make')
        sudo('make install')
    run('rm -rf {}*'.format(DIR_OTP))


@task
def install_git():
    """Build and install Git."""
    if run('which git', quiet=True).return_code != 0:
        sudo('apt-get -q -y install git')


@task
def install_rebar():
    """Build and install the rebar build tool."""
    install_git()
    run('git clone -q https://github.com/rebar/rebar.git')
    with cd('rebar'):
        run('git checkout 2.6.1')
        run('./bootstrap')
        sudo('cp rebar /usr/local/bin')
    run('rm -rf rebar')
