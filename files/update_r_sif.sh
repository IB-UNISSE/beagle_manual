#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# update_r_sif.sh
#
# Actualiza imágenes R de Apptainer.
#
# Soporta:
#   --apt   Paquetes Debian
#   --r     Paquetes CRAN
#   --bioc  Paquetes Bioconductor
#
# En Slurm usa automáticamente:
#
#   /tmp/$USER/$SLURM_JOB_ID
#
# para evitar trabajar sobre almacenamiento compartido.
# ============================================================


# ============================================================
# Configuración
# ============================================================

R_REPO="https://cloud.r-project.org"

# Si estamos dentro de Slurm, toma automáticamente
# SLURM_CPUS_PER_TASK. Fuera de Slurm utiliza 4.
R_NCPUS="${SLURM_CPUS_PER_TASK:-${R_NCPUS:-4}}"

IMAGE=""

APT_PACKAGES=()
R_PACKAGES=()
BIOC_PACKAGES=()


# ============================================================
# Ayuda
# ============================================================

usage() {

cat <<'EOF'

Actualizador de imágenes R / Apptainer
=======================================

Uso:

  update_r_sif.sh -i IMAGEN [opciones]


OPCIONES

  -i, --image FILE

      Imagen SIF que se desea actualizar.

      La extensión .sif es opcional.


  --apt PKG...

      Instala uno o varios paquetes Debian
      utilizando apt-get.


  --r PKG...

      Instala uno o varios paquetes R desde CRAN.


  --bioc PKG...

      Instala uno o varios paquetes Bioconductor.


  -h, --help

      Muestra esta ayuda.


EJEMPLOS


1. Instalar un paquete CRAN:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --r ape


2. Instalar varios paquetes CRAN:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --r ape phytools terra


3. Instalar dependencias Debian:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --apt \
          libxml2-dev \
          libcurl4-openssl-dev \
          libssl-dev


4. Debian + CRAN:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --apt \
          libgdal-dev \
          libgeos-dev \
          libproj-dev \
          libsqlite3-dev \
      --r terra


5. Bioconductor:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --bioc \
          DESeq2 \
          edgeR \
          Biostrings


6. Tidyverse con dependencias del sistema:

  ./update_r_sif.sh \
      -i r-base_4.6.1.sif \
      --apt \
          libcurl4-openssl-dev \
          libuv1-dev \
          libxml2-dev \
          libssl-dev \
          libfontconfig1-dev \
          libfreetype-dev \
          libharfbuzz-dev \
          libfribidi-dev \
          libpng-dev \
          libtiff-dev \
          libjpeg-dev \
      --r tidyverse


FUNCIONAMIENTO

  1. Verifica Apptainer y fakeroot.

  2. Si se ejecuta mediante Slurm utiliza:

       /tmp/$USER/$SLURM_JOB_ID

     como almacenamiento temporal local.

  3. Convierte el SIF a sandbox.

  4. Instala paquetes Debian, CRAN y/o Bioconductor.

  5. Verifica los paquetes solicitados.

  6. Construye un nuevo SIF.

  7. Conserva un respaldo de la imagen anterior.

  8. Sustituye la imagen original únicamente si todo terminó
     correctamente.


EOF
}


# ============================================================
# Sin argumentos -> ayuda
# ============================================================

if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi


# ============================================================
# Leer argumentos
# ============================================================

MODE=""

while [[ $# -gt 0 ]]; do

    case "$1" in

        -i|--image)

            if [[ $# -lt 2 ]]; then
                echo "ERROR: falta el nombre de la imagen."
                exit 1
            fi

            IMAGE="$2"
            MODE=""
            shift 2
            ;;


        --apt)

            MODE="apt"
            shift
            ;;


        --r)

            MODE="r"
            shift
            ;;


        --bioc)

            MODE="bioc"
            shift
            ;;


        -h|--help)

            usage
            exit 0
            ;;


        -*)

            echo
            echo "ERROR: opción desconocida:"
            echo
            echo "  $1"
            echo
            usage
            exit 1
            ;;


        *)

            case "$MODE" in

                apt)
                    APT_PACKAGES+=("$1")
                    ;;

                r)
                    R_PACKAGES+=("$1")
                    ;;

                bioc)
                    BIOC_PACKAGES+=("$1")
                    ;;

                *)
                    echo
                    echo "ERROR: argumento inesperado:"
                    echo
                    echo "  $1"
                    echo
                    usage
                    exit 1
                    ;;

            esac

            shift
            ;;

    esac

done


# ============================================================
# Comprobar Apptainer
# ============================================================

if ! command -v apptainer >/dev/null 2>&1; then

    echo
    echo "ERROR: no se encontró Apptainer."
    echo

    exit 1

fi


# ============================================================
# Comprobar imagen
# ============================================================

if [[ -z "$IMAGE" ]]; then

    echo
    echo "ERROR: debes indicar una imagen con:"
    echo
    echo "  -i imagen.sif"
    echo

    exit 1

fi


if [[ "$IMAGE" != *.sif ]]; then
    IMAGE="${IMAGE}.sif"
fi


# Convertir a ruta absoluta.
#
# Esto es importante porque posteriormente trabajaremos
# dentro de /tmp.
IMAGE="$(readlink -f "$IMAGE")"


if [[ ! -f "$IMAGE" ]]; then

    echo
    echo "ERROR: no existe la imagen:"
    echo
    echo "  $IMAGE"
    echo

    exit 1

fi


# ============================================================
# Comprobar paquetes
# ============================================================

if [[ ${#APT_PACKAGES[@]} -eq 0 \
   && ${#R_PACKAGES[@]} -eq 0 \
   && ${#BIOC_PACKAGES[@]} -eq 0 ]]; then

    echo
    echo "ERROR: no especificaste ningún paquete."
    echo

    usage
    exit 1

fi


# ============================================================
# Rutas de la imagen
# ============================================================

IMAGE_DIR="$(dirname "$IMAGE")"
IMAGE_FILE="$(basename "$IMAGE")"

BASENAME="${IMAGE_FILE%.sif}"

TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"


# ============================================================
# Directorio temporal
# ============================================================

if [[ -n "${SLURM_JOB_ID:-}" ]]; then

    # --------------------------------------------------------
    # Slurm / BEAGLE
    # --------------------------------------------------------

    WORKDIR="/tmp/${USER}/${SLURM_JOB_ID}"

else

    # --------------------------------------------------------
    # Ejecución normal, por ejemplo Maginot
    # --------------------------------------------------------

    WORKDIR="/tmp/${USER}/apptainer-${BASENAME}-$$"

fi


SANDBOX="${WORKDIR}/${BASENAME}-sandbox"

NEW_IMAGE="${WORKDIR}/${BASENAME}-new.sif"

BACKUP="${IMAGE_DIR}/${BASENAME}_${TIMESTAMP}.sif"


mkdir -p "$WORKDIR"


# ============================================================
# Temporales de Apptainer y R
# ============================================================

export APPTAINER_TMPDIR="$WORKDIR"
export TMPDIR="$WORKDIR"


# ============================================================
# Función de limpieza
# ============================================================

cleanup() {

    EXIT_CODE=$?

    echo

    if [[ -d "$WORKDIR" ]]; then

        echo "Limpiando:"
        echo
        echo "  $WORKDIR"
        echo

        rm -rf "$WORKDIR" 2>/dev/null || true

    fi

    if [[ $EXIT_CODE -ne 0 ]]; then

        echo
        echo "============================================================"
        echo " ERROR: actualización abortada"
        echo "============================================================"
        echo
        echo "La imagen original NO fue reemplazada:"
        echo
        echo "  $IMAGE"
        echo

    fi

}

trap cleanup EXIT


# ============================================================
# Información del entorno
# ============================================================

echo
echo "============================================================"
echo " Actualizador R / Apptainer"
echo "============================================================"
echo

echo "Host:"
echo
hostname
echo


if [[ -n "${SLURM_JOB_ID:-}" ]]; then

    echo "Slurm job:"
    echo
    echo "  $SLURM_JOB_ID"
    echo

fi


echo "Imagen:"
echo
echo "  $IMAGE"
echo

echo "Directorio temporal:"
echo
echo "  $WORKDIR"
echo

echo "CPUs para compilación R:"
echo
echo "  $R_NCPUS"
echo


echo "Espacio disponible en temporales:"
echo

df -h "$WORKDIR"

echo


# ============================================================
# Mostrar paquetes solicitados
# ============================================================

if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then

    echo "Paquetes Debian:"
    printf '  - %s\n' "${APT_PACKAGES[@]}"
    echo

fi


if [[ ${#R_PACKAGES[@]} -gt 0 ]]; then

    echo "Paquetes CRAN:"
    printf '  - %s\n' "${R_PACKAGES[@]}"
    echo

fi


if [[ ${#BIOC_PACKAGES[@]} -gt 0 ]]; then

    echo "Paquetes Bioconductor:"
    printf '  - %s\n' "${BIOC_PACKAGES[@]}"
    echo

fi


# ============================================================
# Comprobar fakeroot
# ============================================================

echo "============================================================"
echo "1. Comprobando fakeroot"
echo "============================================================"
echo


apptainer exec \
    --fakeroot \
    --pwd / \
    "$IMAGE" \
    id


echo
echo "Fakeroot: OK"
echo


# ============================================================
# Crear sandbox
# ============================================================

echo "============================================================"
echo "2. Creando sandbox"
echo "============================================================"
echo

echo "Origen:"
echo
echo "  $IMAGE"
echo

echo "Destino:"
echo
echo "  $SANDBOX"
echo


time apptainer build \
    --fakeroot \
    --sandbox \
    "$SANDBOX" \
    "$IMAGE"


# ============================================================
# Paquetes Debian
# ============================================================

if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "============================================================"
    echo "3. Instalando paquetes Debian"
    echo "============================================================"
    echo


    apptainer exec \
        --fakeroot \
        --writable \
        --pwd / \
        "$SANDBOX" \
        env DEBIAN_FRONTEND=noninteractive \
        apt-get update


    echo


    apptainer exec \
        --fakeroot \
        --writable \
        --pwd / \
        "$SANDBOX" \
        env DEBIAN_FRONTEND=noninteractive \
        apt-get install \
        -y \
        --no-install-recommends \
        "${APT_PACKAGES[@]}"


    echo
    echo "Limpiando APT..."
    echo


    apptainer exec \
        --fakeroot \
        --writable \
        --pwd / \
        "$SANDBOX" \
        apt-get clean


    apptainer exec \
        --fakeroot \
        --writable \
        --pwd / \
        "$SANDBOX" \
        bash -c 'rm -rf /var/lib/apt/lists/*'

fi


# ============================================================
# Paquetes CRAN
# ============================================================

if [[ ${#R_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "============================================================"
    echo "4. Instalando paquetes CRAN"
    echo "============================================================"


    for PACKAGE in "${R_PACKAGES[@]}"; do


        if [[ ! "$PACKAGE" =~ ^[A-Za-z0-9._]+$ ]]; then

            echo
            echo "ERROR: nombre de paquete R no válido:"
            echo
            echo "  $PACKAGE"
            echo

            exit 1

        fi


        echo
        echo "------------------------------------------------------------"
        echo "CRAN :: $PACKAGE"
        echo "------------------------------------------------------------"
        echo


        apptainer exec \
            --fakeroot \
            --writable \
            --pwd / \
            "$SANDBOX" \
            Rscript -e "
                options(
                    repos = c(
                        CRAN = '$R_REPO'
                    ),
                    Ncpus = $R_NCPUS
                )

                install.packages(
                    '$PACKAGE',
                    Ncpus = $R_NCPUS
                )
            "

    done

fi


# ============================================================
# Bioconductor
# ============================================================

if [[ ${#BIOC_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "============================================================"
    echo "5. Instalando paquetes Bioconductor"
    echo "============================================================"
    echo


    echo "Comprobando BiocManager..."
    echo


    apptainer exec \
        --fakeroot \
        --writable \
        --pwd / \
        "$SANDBOX" \
        Rscript -e "
            options(
                repos = c(
                    CRAN = '$R_REPO'
                ),
                Ncpus = $R_NCPUS
            )

            if (!requireNamespace(
                    'BiocManager',
                    quietly = TRUE
                )) {

                install.packages(
                    'BiocManager',
                    Ncpus = $R_NCPUS
                )

            }
        "


    for PACKAGE in "${BIOC_PACKAGES[@]}"; do


        if [[ ! "$PACKAGE" =~ ^[A-Za-z0-9._]+$ ]]; then

            echo
            echo "ERROR: nombre de paquete Bioconductor no válido:"
            echo
            echo "  $PACKAGE"
            echo

            exit 1

        fi


        echo
        echo "------------------------------------------------------------"
        echo "Bioconductor :: $PACKAGE"
        echo "------------------------------------------------------------"
        echo


        apptainer exec \
            --fakeroot \
            --writable \
            --pwd / \
            "$SANDBOX" \
            Rscript -e "
                options(
                    Ncpus = $R_NCPUS
                )

                BiocManager::install(
                    '$PACKAGE',
                    ask = FALSE,
                    update = FALSE,
                    Ncpus = $R_NCPUS
                )
            "

    done

fi


# ============================================================
# Verificar R
# ============================================================

echo
echo "============================================================"
echo "6. Verificando R"
echo "============================================================"
echo


apptainer exec \
    --pwd / \
    "$SANDBOX" \
    Rscript -e '
        cat(R.version.string, "\n")
        print(.libPaths())
    '


# ============================================================
# Verificar CRAN
# ============================================================

if [[ ${#R_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "Paquetes CRAN:"
    echo


    for PACKAGE in "${R_PACKAGES[@]}"; do

        apptainer exec \
            --pwd / \
            "$SANDBOX" \
            Rscript -e "
                if (!requireNamespace(
                        '$PACKAGE',
                        quietly = TRUE
                    )) {

                    stop(
                        'El paquete $PACKAGE no quedó instalado'
                    )

                }

                cat(
                    '$PACKAGE',
                    as.character(
                        packageVersion('$PACKAGE')
                    ),
                    '\n'
                )
            "

    done

fi


# ============================================================
# Verificar Bioconductor
# ============================================================

if [[ ${#BIOC_PACKAGES[@]} -gt 0 ]]; then

    echo
    echo "Paquetes Bioconductor:"
    echo


    for PACKAGE in "${BIOC_PACKAGES[@]}"; do

        apptainer exec \
            --pwd / \
            "$SANDBOX" \
            Rscript -e "
                if (!requireNamespace(
                        '$PACKAGE',
                        quietly = TRUE
                    )) {

                    stop(
                        'El paquete $PACKAGE no quedó instalado'
                    )

                }

                cat(
                    '$PACKAGE',
                    as.character(
                        packageVersion('$PACKAGE')
                    ),
                    '\n'
                )
            "

    done

fi


# ============================================================
# Construir nuevo SIF
# ============================================================

echo
echo "============================================================"
echo "7. Construyendo nuevo SIF"
echo "============================================================"
echo

echo "Sandbox:"
echo
echo "  $SANDBOX"
echo

echo "Nuevo SIF temporal:"
echo
echo "  $NEW_IMAGE"
echo


time apptainer build \
    --fakeroot \
    "$NEW_IMAGE" \
    "$SANDBOX"


# ============================================================
# Verificar nuevo SIF
# ============================================================

echo
echo "============================================================"
echo "8. Verificando nuevo SIF"
echo "============================================================"
echo


apptainer exec \
    --pwd / \
    "$NEW_IMAGE" \
    Rscript -e '
        cat(R.version.string, "\n")
    '


# ============================================================
# Backup
# ============================================================

echo
echo "============================================================"
echo "9. Guardando respaldo"
echo "============================================================"
echo


echo "Imagen anterior:"
echo
echo "  $IMAGE"
echo

echo "Backup:"
echo
echo "  $BACKUP"
echo


cp -p "$IMAGE" "$BACKUP"


# ============================================================
# Reemplazar imagen original
# ============================================================

echo
echo "============================================================"
echo "10. Instalando nueva imagen"
echo "============================================================"
echo


# Copiar primero con nombre temporal en el filesystem destino.
#
# Esto evita dejar una imagen incompleta si una copia falla.
DEST_TMP="${IMAGE}.new-${TIMESTAMP}"


cp "$NEW_IMAGE" "$DEST_TMP"


# Verificar también la copia final antes del reemplazo.
apptainer exec \
    --pwd / \
    "$DEST_TMP" \
    Rscript -e '
        cat("Verificación final:", R.version.string, "\n")
    '


# mv dentro del mismo filesystem es atómico.
mv -f "$DEST_TMP" "$IMAGE"


# ============================================================
# Resultado
# ============================================================

echo
echo "============================================================"
echo " ACTUALIZACIÓN COMPLETADA"
echo "============================================================"
echo

echo "Imagen actual:"
echo
echo "  $IMAGE"
echo

echo "Backup:"
echo
echo "  $BACKUP"
echo

echo "R:"
echo


apptainer exec \
    --pwd / \
    "$IMAGE" \
    Rscript -e '
        cat(R.version.string, "\n")
    '


echo
echo "La imagen fue actualizada correctamente."
echo


# ============================================================
# Final correcto
# ============================================================

trap - EXIT

rm -rf "$WORKDIR"

exit 0