"""Render the nginx Jinja2 templates to catch syntax errors and broken includes.

This does not validate nginx semantics; that happens with `nginx -t` on the
server during deploy. Every undeclared variable gets a dummy value, so a
missing default is not reported here.
"""

import re
from pathlib import Path

import jinja2
import pytest
from jinja2 import meta

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE_DIRS = [
    ROOT / "ansible-roles/nginx-ssl/templates",
    ROOT / "ansible-roles/nginx/templates",
]


def _regex_replace(value: str, pattern: str, replacement: str = "") -> str:
    # Ansible filter, same signature for the subset the templates use.
    return re.sub(pattern, replacement, str(value))


ENV = jinja2.Environment(
    loader=jinja2.FileSystemLoader([str(d) for d in TEMPLATE_DIRS]),
    undefined=jinja2.Undefined,
    keep_trailing_newline=True,
)
ENV.filters["regex_replace"] = _regex_replace


def _render(name: str) -> str:
    source, _, _ = ENV.loader.get_source(ENV, name)
    names = meta.find_undeclared_variables(ENV.parse(source))
    return ENV.from_string(source).render({n: "x" for n in names})


@pytest.mark.parametrize("name", ["vhost-ssl.conf.j2", "nginx.conf.j2"])
def test_template_renders(name: str) -> None:
    assert _render(name).strip()


def test_vhost_has_csp_report_collector() -> None:
    # The Report-Only collector is the only source of CSP violation data (see H1).
    rendered = _render("vhost-ssl.conf.j2")
    assert "location = /csp-report" in rendered
    assert "proxy_pass http://127.0.0.1:8099;" in rendered
