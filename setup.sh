#!/bin/bash

# Функция установки пакетов с разными пакетными менеджерами
install_packages() {
  case "$1" in
    brew)
      brew install wget git ;;
    *)
      echo "Неизвестный пакетный менеджер: $1"
      return 1 ;;
  esac
}

# Проверяем, есть ли wget и git — если да, переходим к следующему коду
if command -v wget &>/dev/null && command -v git &>/dev/null; then
  echo "wget и git уже установлены, продолжаем..."
else
  # Определяем пакетный менеджер и выполняем установку
  if command -v brew &>/dev/null; then
    echo "Обнаружен brew, устанавливаем wget и git..."
    install_packages brew
  else
    echo "Не удалось определить пакетный менеджер."
    echo "Необходимо установить wget и git вручную."
    exit 1
  fi
fi

# Создаем временную директорию, если она не существует
mkdir -p "$HOME/tmp"
# Удаление архива с запретом на всякий
rm -rf "$HOME/tmp/*"

# Бэкап запрета если есть
if [ -d "/opt/zapret" ]; then
  echo "Создание резервной копии существующего zapret..."
  sudo cp -r "/opt/zapret" "/opt/zapret.bak"
fi
sudo rm -rf "/opt/zapret"

# Получение последней версии zapret с GitHub API
echo "Определение последней версии zapret..."
ZAPRET_VERSION=$(curl -s "https://api.github.com/repos/bol-van/zapret/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$ZAPRET_VERSION" ]; then
  echo "Не удалось получить версию через GitHub API. Используем git ls-remote..."
  
  # Получить все теги, отсортировать их по версии и выбрать последний
  ZAPRET_VERSION=$(git ls-remote --tags https://github.com/bol-van/zapret.git | 
                  grep -v '\^{}' | # Исключаем аннотированные теги
                  awk -F/ '{print $NF}' | # Извлекаем только имя тега
                  sort -V | # Сортируем по версии
                  tail -n 1) # Берем последний тег
  
  if [ -z "$ZAPRET_VERSION" ]; then
    echo "Ошибка: не удалось определить последнюю версию zapret через git ls-remote."
    exit 1
  fi
fi

echo "Последняя версия zapret: $ZAPRET_VERSION"

# Закачка последнего релиза bol-van/zapret
echo "Скачивание последнего релиза zapret..."
if ! wget -O "$HOME/tmp/zapret-$ZAPRET_VERSION.tar.gz" "https://github.com/bol-van/zapret/releases/download/$ZAPRET_VERSION/zapret-$ZAPRET_VERSION.tar.gz"; then
  echo "Ошибка: не удалось скачать zapret."
  exit 1
fi

# Распаковка архива
echo "Распаковка zapret..."
if ! tar -xvf "$HOME/tmp/zapret-$ZAPRET_VERSION.tar.gz" -C "$HOME/tmp"; then
  echo "Ошибка: не удалось распаковать zapret."
  exit 1
fi

# Версия без 'v' в начале для работы с директорией
ZAPRET_DIR_VERSION=$(echo $ZAPRET_VERSION | sed 's/^v//')
echo "Определение пути распакованного архива..."

# Проверяем наличие директорий с разными вариантами именования
if [ -d "$HOME/tmp/zapret-$ZAPRET_DIR_VERSION" ]; then
  ZAPRET_EXTRACT_DIR="$HOME/tmp/zapret-$ZAPRET_DIR_VERSION"
elif [ -d "$HOME/tmp/zapret-$ZAPRET_VERSION" ]; then
  ZAPRET_EXTRACT_DIR="$HOME/tmp/zapret-$ZAPRET_VERSION"
else
  # Если не нашли конкретные варианты, ищем любую папку zapret-*
  ZAPRET_EXTRACT_DIR=$(find "$HOME/tmp" -type d -name "zapret-*" | head -n 1)
  if [ -z "$ZAPRET_EXTRACT_DIR" ]; then
    echo "Ошибка: не удалось найти распакованную директорию zapret."
    echo "Содержимое $HOME/tmp:"
    ls -la "$HOME/tmp"
    exit 1
  fi
fi

echo "Найден распакованный каталог: $ZAPRET_EXTRACT_DIR"

# Перемещение zapret в /opt/zapret
echo "Перемещение zapret в /opt/zapret..."
if ! sudo mv "$ZAPRET_EXTRACT_DIR" "/opt/zapret"; then
  echo "Ошибка: не удалось переместить zapret в /opt/zapret."
  exit 1
fi

# Клонирование репозитория с конфигами
echo "Клонирование репозитория с конфигами..."
if ! git clone https://github.com/SoKnight/zapret-discord-youtube-macos.git "$HOME/zapret-configs"; then
  rm -rf $HOME/zapret-configs
  if ! git clone https://github.com/SoKnight/zapret-discord-youtube-macos.git "$HOME/zapret-configs"; then
    echo "Ошибка: не удалось клонировать репозиторий с конфигами."
  exit 1
  fi
fi

# Копирование hostlists
echo "Копирование hostlists..."
if ! sudo cp -r "$HOME/zapret-configs/hostlists" /opt/zapret/hostlists; then
  echo "Ошибка: не удалось скопировать hostlists."
  exit 1
fi

# Запуск второго скрипта
echo "Запуск install.sh..."
if ! bash "$HOME/zapret-configs/install.sh"; then
  echo "Ошибка: не удалось запустить install.sh."
  exit 1
fi
