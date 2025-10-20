from time import strftime, localtime

def get_current_time():
    return strftime("%Y-%m-%d %H:%M:%S", localtime())

if __name__ == "__main__":
    print(get_current_time())