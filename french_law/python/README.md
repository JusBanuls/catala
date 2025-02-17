# Python French Law Library

This folder contains a ready-to-use Python library featuring French public
algorithms coded up in Catala.

The Python version expected to run the Python code is above 3.6. For the commands
noted below to run, you are expected to setup a virtual Python environment with
`virtualenv` by running the `setup_env.sh` script.

## Organization

### Law source

The `src/` folder contains the Python files generated by the Catala compiler.
To update them from the Catala sources, invoke this command from the root
of the repository:

```
make generate_french_law_library_python
```

The Python files generated by the Catala compiler depends on the `catala.runtime`
package, whose source doe can be found in `runtimes/python/catala` from the
root of the Catala repository.

All theses Python files feature type annotations which can be checked against
using the following command inside this directory (`french_law/python`):

```
make type
```

### API

To use the algorithms of this library, you can take a look at the example provided in
`main.py`. All the algorithms are centralized with wrappers in `api.py`, as it is
very important internally to wrap all of the input parameters using `src/catala.py`
conversion functions.

You can benchmark the computation using the following command inside this
directory (`french_law/python`):

```
make bench
```

### Logging

The generated Catala code also features a logging feature that let you inspect
each step of the computation, as well as the values flowing through it. You can
directly retrieve a list of log events just after using a Catala-generated
function, and display this list as you wish. An example of such a display can
be showcases by using the following command inside this directory (`french_law/python`):

```
make show_log
```
